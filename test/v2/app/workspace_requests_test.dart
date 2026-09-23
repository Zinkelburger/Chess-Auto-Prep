import 'dart:async';

import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/app/mode.dart';
import 'package:chess_auto_prep/v2/app/window_input.dart';
import 'package:chess_auto_prep/v2/app/workspace_requests.dart';
import 'package:chess_auto_prep/v2/chess/explorer_answer.dart';
import 'package:chess_auto_prep/v2/chess/explorer_choice.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/study.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/study_fixture.dart';
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

  group('openAt', () {
    test('opens the chapter at the position the moves reach', () async {
      expect(
        await w.requests.openAt(kid, ['c5', 'Nc3', 'Nc6']),
        isA<RequestDone>(),
      );
      expect(w.session.source, kid);
      expect(w.session.cursor, NodePath.of([0, 1, 0]));
    });

    test('goes as far along the moves as the chapter still does', () async {
      await w.requests.openAt(kid, ['c5', 'Nc3', 'e5']);
      expect(w.session.cursor, NodePath.of([0, 1]));
    });

    test('a chapter that cannot open goes nowhere', () async {
      w.store.documents.clear();
      expect(await w.requests.openAt(kid, ['c5']), isA<RequestRefused>());
      expect(w.session.source, isNull);
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

    test('a copy on the way out that could not be written says why, and '
        'the chapter stays', () async {
      await freezeKid();
      w.question.answer = DraftChoice.saveACopy;
      w.store.creates.add(const IoFailure('disk full'));
      expect(await w.requests.open(benko), isA<RequestDropped>());
      expect(w.session.source, kid);
      expect(w.requests.status, 'Could not save a copy: disk full');

      w.store.creates.add(const Collision());
      expect(await w.requests.open(benko), isA<RequestDropped>());
      expect(w.requests.status, 'That name is taken. Nothing was replaced.');
    });
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
        // The list is read before it is written, a turn later.
        await pumpEventQueue();
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

    /// Asked from the Masters table, at the ply the explorer is showing.
    Future<RequestResult> openListed() => w.requests.openExplorerGame(
      game,
      source: ExplorerSource.masters,
      ply: w.explorer.ply,
    );

    test(
      'is kept as a file and opened in the viewer at the explorer ply',
      () async {
        await w.requests.open(kid);
        w.session.forward();
        final ply = w.explorer.ply;
        expect(ply, greaterThan(0));
        expect(await openListed(), isA<RequestDone>());
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
      final result = await openListed();
      expect((result as RequestRefused).sentence, 'Could not fetch that game.');
      expect(w.requests.status, 'Could not fetch that game.');
      expect(w.requests.mode, Mode.repertoires);
      expect(w.session.source, kid);
    });

    test('is not opened over a draft the user stays with', () async {
      await freezeKid();
      w.question.answer = DraftChoice.keepWaiting;
      expect(await openListed(), isA<RequestDropped>());
      expect(w.session.source, kid);
    });

    test('that lands after the user opened another chapter is dropped, '
        'not opened over it', () async {
      await w.requests.open(kid);
      w.store.hold = true;
      final listed = openListed();
      await pumpEventQueue();
      final chosen = w.requests.open(benko);
      await pumpEventQueue();
      w.store.releaseLast(); // benko's read, asked for last
      expect(await chosen, isA<RequestDone>());
      w.store.hold = false;
      w.store.releaseAll(); // the game's file is written
      expect(await listed, isA<RequestDropped>());
      expect(w.requests.mode, Mode.repertoires);
      expect(w.session.source, benko);
      expect(w.requests.status, isNull);
    });

    test('from This file is put on the board where its main line reaches '
        'the position, by its own move order, reading and keeping '
        'nothing', () async {
      const transposed = '''
[Event "A"]
[Result "1-0"]

1. d4 Nf6 2. c4 e6 3. Nc3 1-0

[Event "B"]
[Result "0-1"]

1. c4 e6 2. d4 Nf6 3. Nf3 0-1
''';
      final games = collectionRef('games');
      w.store.documents[games] = Opened(
        transposed,
        scriptedRevision(transposed),
      );
      await w.requests.openFile(games);
      w.session.goTo(NodePath.of(const [0, 0, 0, 0]));
      final shared = w.session.fen;
      final result = await w.requests.openExplorerGame(
        const ExplorerGame(id: '1', white: '', black: '', result: '0-1'),
        source: ExplorerSource.thisFile,
        ply: w.explorer.ply,
      );
      expect(result, isA<RequestDone>());
      expect(w.session.source, games);
      expect(w.session.game, 1);
      expect(w.session.cursor, NodePath.of(const [0, 0, 0, 0]));
      expect(w.session.fen.position, shared.position);
      expect(w.session.currentMove?.san, 'Nf6');
      expect(w.store.creates, isEmpty);
    });
  });

  group('the analysis board', () {
    test('is where the window starts, and Ctrl+V pastes onto it', () async {
      expect(w.session.isScratch, isTrue);
      input.clipboardText = '1.e4 c5 2.Nf3';
      expect(await w.requests.pasteOntoBoard(), isA<RequestDone>());
      expect(w.session.currentMove?.san, 'Nf3');
      expect(w.store.creates, isEmpty);
    });

    test('a paste with no game says why and changes nothing', () async {
      input.clipboardText = 'no moves here';
      final result = await w.requests.pasteOntoBoard();
      expect(result, isA<RequestRefused>());
      expect(w.requests.status, startsWith('The clipboard holds no game'));
      expect(w.session.tree!.children, isEmpty);
    });

    test('a new board from a chapter keeps its line and side', () async {
      await w.requests.open(kid);
      w.session
        ..forward()
        ..forward();
      expect(await w.requests.newAnalysisBoard(), isA<RequestDone>());
      expect(w.session.isScratch, isTrue);
      expect(w.session.orientation, Side.black);
      expect(w.session.currentMove?.san, 'Nf3');
    });

    test('is gone back to as it was left', () async {
      w.session.playMove('d2d4');
      await w.requests.open(kid);
      expect(await w.requests.analysisBoard(), isA<RequestDone>());
      expect(w.session.currentMove?.san, 'd4');
    });

    test(
      'is not left for a chapter over a draft the user stays with',
      () async {
        await freezeKid();
        w.question.answer = DraftChoice.keepWaiting;
        expect(await w.requests.analysisBoard(), isA<RequestDropped>());
        expect(w.session.source, kid);
      },
    );
  });

  group('keeping the analysis board', () {
    test(
      'saved to a repertoire becomes a chapter open in the builder',
      () async {
        w.requests.switchTo(Mode.study);
        w.session
          ..playMove('e2e4')
          ..playMove('e7e5');
        await w.library.refresh();
        final into = w.library.repertoires.firstWhere((f) => f.name == 'KID');
        final result = await w.requests.saveBoardToRepertoire(
          into,
          'Open game',
        );
        expect(result, isA<RequestDone>());
        expect(w.requests.mode, Mode.repertoires);
        expect(w.session.source?.path, '/repertoires/KID/Open game.pgn');
        expect(w.session.chapter!.side, Side.white);
        expect(w.session.tree!.children.single.san, 'e4');
        await w.requests.analysisBoard();
        expect(w.session.currentMove?.san, 'e5', reason: 'the board is kept');
      },
    );

    test('saved to a study becomes its last chapter', () async {
      final study = ChapterRef.at('$studiesRoot/Ideas.pgn');
      final text = newStudyText(study: 'Ideas', chapter: 'Intro');
      w.store.documents[study] = Opened(text, scriptedRevision(text));
      w.session.playMove('d2d4');
      expect(
        await w.requests.saveBoardToStudy(study, 'Queen pawn'),
        isA<RequestDone>(),
      );
      expect(w.requests.mode, Mode.study);
      expect(w.session.source, study);
      expect(w.session.game, 1);
      expect(w.session.tree!.children.single.san, 'd4');
      await pumpEventQueue();
      expect(w.store.requestedSaves, isNotEmpty);
    });
  });

  group('mode and status', () {
    test('a switch of mode is said once; the same mode is not a change', () {
      var notified = 0;
      w.requests.addListener(() => notified++);
      w.requests.switchTo(Mode.study);
      expect(w.requests.mode, Mode.study);
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
