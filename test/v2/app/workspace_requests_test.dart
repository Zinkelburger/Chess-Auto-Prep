import 'dart:async';

import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/app/mode.dart';
import 'package:chess_auto_prep/v2/app/window_input.dart';
import 'package:chess_auto_prep/v2/app/workspace_requests.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/explorer.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  final kid = kidMain;
  final benko = benkoMain;
  const pasted = '[Event "x"]\n[Result "*"]\n\n1. e4 e5 (1... c5) *\n';
  const unsaid = '[Event "Open"]\n[Result "*"]\n\n1. e4 e5 *\n';

  late _Input input;
  late WindowFixture w;

  setUp(() {
    input = _Input();
    w = WindowFixture(input: input);
  });

  tearDown(() => w.dispose());

  /// Opens KID and leaves a comment its file refused, so the next document
  /// has a draft to ask about.
  Future<void> freezeKid() async {
    await w.requests.open(kid);
    w.store.saves.add(const SaveRefused('game 3 would change'));
    w.session.setComment(NodePath.of([0]), 'frozen words');
    await pumpEventQueue();
  }

  group('open', () {
    test('puts a chapter on the board and says nothing', () async {
      expect(await w.requests.open(kid), isA<RequestDone>());
      expect(w.session.source, kid);
      expect(w.requests.status, isNull);
    });

    test('a chapter that vanished is refused in a sentence', () async {
      w.store.documents.clear();
      final result = await w.requests.open(kid);
      expect(result, isA<RequestRefused>());
      expect((result as RequestRefused).sentence, 'Main is no longer on disk');
      expect(w.requests.status, 'Main is no longer on disk');
      expect(w.session.source, isNull);
    });

    test('an open a later one overtook drops without a word', () async {
      w.store.hold = true;
      final first = w.requests.open(kid);
      final second = w.requests.open(benko);
      await pumpEventQueue();
      w.store.releaseAll();
      expect(await first, isA<RequestDropped>());
      expect(await second, isA<RequestDone>());
      expect(w.session.source, benko);
      expect(w.requests.status, isNull);
    });
  });

  group('open over a draft the file refused', () {
    test('the chapter already open is not left, so nothing is asked', () async {
      await freezeKid();
      expect(await w.requests.open(kid), isA<RequestDone>());
      expect(w.question.asked, isEmpty);
    });

    test('staying with a frozen draft opens nothing', () async {
      await freezeKid();
      w.question.answer = DraftChoice.keepWaiting;
      expect(await w.requests.open(benko), isA<RequestDropped>());
      expect(w.question.asked.single, contains('was stopped'));
      expect(w.session.source, kid);
      expect(w.requests.status, isNull);
    });

    test(
      'a copy saved on the way out is said once the chapter is open',
      () async {
        await freezeKid();
        w.question.answer = DraftChoice.saveACopy;
        expect(await w.requests.open(benko), isA<RequestDone>());
        expect(w.session.source, benko);
        expect(w.requests.status, 'Saved a copy as Main copy.pgn');
        expect(
          w.store.documents.keys.map((ref) => ref.path),
          contains('/repertoires/KID/Main copy.pgn'),
        );
      },
    );
  });

  group('the side question', () {
    setUp(() {
      w.store.documents[benko] = Opened(unsaid, scriptedRevision(unsaid));
    });

    test(
      'a chapter that does not say is asked once and the answer kept',
      () async {
        input.side = Side.black;
        await w.requests.open(benko);
        await pumpEventQueue();
        expect(input.sidesAsked, ['Main']);
        expect(w.session.chapter?.side, Side.black);
        expect(w.session.chapter?.sideStated, isTrue);
      },
    );

    test('a chapter that says is not asked', () async {
      await w.requests.open(kid);
      await pumpEventQueue();
      expect(input.sidesAsked, isEmpty);
    });

    test('dismissing it leaves the file as it was', () async {
      await w.requests.open(benko);
      await pumpEventQueue();
      expect(input.sidesAsked, ['Main']);
      expect(w.session.chapter?.sideStated, isFalse);
    });

    test(
      'an answer that comes after another chapter opened is dropped',
      () async {
        final answer = input.holdSide = Completer<Side?>();
        await w.requests.open(benko);
        await w.requests.open(kid);
        answer.complete(Side.white);
        await pumpEventQueue();
        expect(w.session.source, kid);
        expect(w.session.chapter?.side, Side.black, reason: 'KID stays Black');
      },
    );
  });

  group('new repertoires', () {
    test('the clipboard becomes a repertoire, opened in the builder', () async {
      w.requests.switchTo(Mode.study);
      input.clipboardText = pasted;
      expect(await w.requests.pasteRepertoire(), isA<RequestDone>());
      expect(w.requests.mode, Mode.repertoires);
      expect(w.session.source?.path, '/repertoires/Pasted repertoire/Main.pgn');
    });

    test('an empty clipboard is refused and writes nothing', () async {
      input.clipboardText = '  ';
      final result = await w.requests.pasteRepertoire();
      expect(
        (result as RequestRefused).sentence,
        'Nothing to paste: copy a PGN first.',
      );
      expect(w.store.creates, isEmpty);
      expect(w.session.source, isNull);
    });

    test('a clipboard with no moves is refused in plain English', () async {
      input.clipboardText = 'just words';
      final result = await w.requests.pasteRepertoire();
      expect(
        (result as RequestRefused).sentence,
        'That PGN has no moves to train.',
      );
      expect(
        w.store.documents.keys.map((ref) => ref.path),
        isNot(contains(contains('Pasted'))),
      );
    });

    test('a closed file dialog imports nothing', () async {
      expect(await w.requests.importFile(), isA<RequestDropped>());
      expect(w.requests.status, isNull);
    });

    test('a file that cannot be read is said in a sentence', () async {
      w.libraryPicker.answer = '/downloads/gone.pgn';
      final result = await w.requests.openPgnFile();
      expect((result as RequestRefused).sentence, 'Could not read that file.');
    });
  });

  group('files in the viewer', () {
    final games = collectionRef('games');

    setUp(() {
      w.store.documents[games] = Opened(
        threeGameFile,
        scriptedRevision(threeGameFile),
      );
    });

    test(
      'Open PGN file outside the builder reads the file in the viewer',
      () async {
        w.requests.switchTo(Mode.study);
        w.viewerPicker.answer = games.path;
        expect(await w.requests.openPgnFile(), isA<RequestDone>());
        expect(w.requests.mode, Mode.pgnViewer);
        expect(w.session.source, games);
        expect(w.session.game, 0);
        expect(w.viewer.file, games);
        expect(w.recent.saved.last, [games.path]);
      },
    );

    test(
      'a recent file opens on its first game, whichever mode asked',
      () async {
        expect(await w.requests.openFile(games), isA<RequestDone>());
        expect(w.requests.mode, Mode.pgnViewer);
        expect(w.session.game, 0);
        expect(w.viewer.file, games);
      },
    );

    test('a file that could not be read is not remembered', () async {
      w.store.documents.remove(games);
      final result = await w.requests.openFile(games);
      expect(result, isA<RequestRefused>());
      expect(w.recent.saved, isEmpty);
    });

    test('Close file takes it off the board', () async {
      await w.requests.openFile(games);
      expect(await w.requests.closeFile(), isA<RequestDone>());
      expect(w.session.source, isNull);
      expect(w.viewer.file, isNull);
    });
  });

  group('Close file', () {
    test('with nothing open does nothing', () async {
      expect(await w.requests.closeFile(), isA<RequestDropped>());
      expect(w.question.asked, isEmpty);
    });

    test('over a draft the user stays with keeps it', () async {
      await freezeKid();
      w.question.answer = DraftChoice.keepWaiting;
      expect(await w.requests.closeFile(), isA<RequestDropped>());
      expect(w.session.source, kid);
    });
  });

  group('a game the explorer lists', () {
    const game = ExplorerGame(
      id: 'abcd1234',
      white: 'Carlsen, M',
      black: 'Nakamura, H',
      result: '1-0',
      year: 2024,
    );

    test(
      'is kept as a file and opened in the viewer at the explorer ply',
      () async {
        await w.requests.open(kid);
        w.session.forward();
        final ply = w.explorer.ply;
        expect(ply, greaterThan(0));
        expect(await w.requests.openExplorerGame(game), isA<RequestDone>());
        expect(w.requests.mode, Mode.pgnViewer);
        expect(w.session.source?.path, contains('/explorer games/'));
        expect(w.session.game, 0);
        expect(w.session.cursor, NodePath.of(List.filled(ply, 0)));
        expect(w.viewer.file, w.session.source);
      },
    );

    test('that could not be fetched is refused and nothing moves', () async {
      await w.requests.open(kid);
      w.lichess.pgn = null;
      final result = await w.requests.openExplorerGame(game);
      expect((result as RequestRefused).sentence, 'Could not fetch that game.');
      expect(w.requests.status, 'Could not fetch that game.');
      expect(w.requests.mode, Mode.repertoires);
      expect(w.session.source, kid);
    });

    test('is not opened over a draft the user stays with', () async {
      await freezeKid();
      w.question.answer = DraftChoice.keepWaiting;
      expect(await w.requests.openExplorerGame(game), isA<RequestDropped>());
      expect(w.session.source, kid);
    });
  });

  group('mode and status', () {
    test('switching to the study list reads it again', () async {
      final before = w.studyFiles.listings;
      var notified = 0;
      w.requests.addListener(() => notified++);
      w.requests.switchTo(Mode.study);
      await pumpEventQueue();
      expect(w.requests.mode, Mode.study);
      expect(w.studyFiles.listings, before + 1);
      w.requests.switchTo(Mode.study);
      expect(notified, 1, reason: 'the same mode is not a change');
    });

    test('say puts a sentence in the bar and takes it out', () {
      w.requests.say('Could not save a copy: disk full');
      expect(w.requests.status, 'Could not save a copy: disk full');
      w.requests.say(null);
      expect(w.requests.status, isNull);
    });
  });
}

/// The window as a test scripts it: the side it answers, or a question
/// held open until the test answers it, and what the clipboard holds.
final class _Input implements WindowInput {
  Side? side;
  Completer<Side?>? holdSide;
  String? clipboardText;
  final sidesAsked = <String>[];

  @override
  Future<Side?> sideFor(String chapter) {
    sidesAsked.add(chapter);
    return holdSide?.future ?? Future.value(side);
  }

  @override
  Future<String?> clipboard() async => clipboardText;
}
