import 'dart:async';

import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/app/mode.dart';
import 'package:chess_auto_prep/v2/app/window_input.dart';
import 'package:chess_auto_prep/v2/app/workspace_requests.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/features/pgn_viewer/pgn_viewer.dart';
import 'package:chess_auto_prep/v2/features/study/studies.dart';
import 'package:chess_auto_prep/v2/net/lichess_studies.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/explorer.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_explorer.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/study_fixture.dart';
import '../support/viewer_fixture.dart';

void main() {
  final kid = ref('KID', 'Main');
  final benko = ref('benko', 'Main');
  const pasted = '[Event "x"]\n[Result "*"]\n\n1. e4 e5 (1... c5) *\n';
  const unsaid = '[Event "Open"]\n[Result "*"]\n\n1. e4 e5 *\n';

  late ScriptedDocumentStore store;
  late DocumentSaver saver;
  late DocumentSession session;
  late ScriptedPicker libraryPicker;
  late Library library;
  late ScriptedStudyFiles studyFiles;
  late Studies studies;
  late ScriptedPicker viewerPicker;
  late ScriptedRecentFiles recent;
  late SettingsStore settings;
  late PgnViewer viewer;
  late ScriptedExplorerApi lichess;
  late Explorer explorer;
  late _Question question;
  late _Input input;
  late WorkspaceRequests requests;

  setUp(() {
    store = ScriptedDocumentStore()
      ..documents[kid] = Opened(blackChapter, scriptedRevision(blackChapter))
      ..documents[benko] = Opened(
        '// Color: White\n',
        scriptedRevision('// Color: White\n'),
      );
    saver = DocumentSaver(store, delay: Duration.zero);
    session = DocumentSession(store, saver);
    libraryPicker = ScriptedPicker();
    library = Library(
      files: ScriptedFiles(
        listing: Repertoires([
          folder('benko', ['Main']),
          folder('KID', ['Main']),
        ]),
      ),
      documents: store,
      session: session,
      saver: saver,
      picker: libraryPicker,
      root: '/repertoires',
    );
    studyFiles = ScriptedStudyFiles();
    studies = Studies(
      files: studyFiles,
      documents: store,
      session: session,
      saver: saver,
      lichess: ScriptedLichess(
        const StudyNotFetched(StudyFetchProblem.unreachable),
      ),
      root: studiesRoot,
    );
    viewerPicker = ScriptedPicker();
    recent = ScriptedRecentFiles();
    settings = SettingsStore();
    viewer = PgnViewer(
      recent: recent,
      picker: viewerPicker,
      import: ScriptedImport(),
      settings: settings,
      session: session,
      collections: collectionsRoot,
    );
    lichess = ScriptedExplorerApi();
    explorer = Explorer(
      session: session,
      settings: settings,
      lichess: lichess,
      book: ScriptedBook(),
      documents: store,
      collections: explorerCollections,
      debounce: Duration.zero,
    );
    question = _Question();
    input = _Input();
    requests = WorkspaceRequests(
      session: session,
      library: library,
      studies: studies,
      viewer: viewer,
      explorer: explorer,
      leaving: ExitGuard(
        saver: saver,
        question: question,
        saveCopy: () async {
          final written = await session.copyAside('Main copy');
          return written is CopySaved ? written.name : null;
        },
        wait: const Duration(milliseconds: 20),
      ),
      input: input,
    );
  });

  tearDown(() {
    requests.dispose();
    explorer.dispose();
    viewer.dispose();
    settings.dispose();
    studies.dispose();
    library.dispose();
    session.dispose();
    saver.dispose();
  });

  /// Opens KID and leaves a comment its file refused, so the next document
  /// has a draft to ask about.
  Future<void> freezeKid() async {
    await requests.open(kid);
    store.saves.add(const SaveRefused('game 3 would change'));
    session.setComment(NodePath.of([0]), 'frozen words');
    await pumpEventQueue();
  }

  group('open', () {
    test('puts a chapter on the board and says nothing', () async {
      expect(await requests.open(kid), isA<RequestDone>());
      expect(session.source, kid);
      expect(requests.status, isNull);
    });

    test('a chapter that vanished is refused in a sentence', () async {
      store.documents.clear();
      final result = await requests.open(kid);
      expect(result, isA<RequestRefused>());
      expect((result as RequestRefused).sentence, 'Main is no longer on disk');
      expect(requests.status, 'Main is no longer on disk');
      expect(session.source, isNull);
    });

    test('the chapter already open is not left, so nothing is asked', () async {
      await freezeKid();
      expect(await requests.open(kid), isA<RequestDone>());
      expect(question.asked, isEmpty);
    });

    test('staying with a frozen draft opens nothing', () async {
      await freezeKid();
      question.answer = DraftChoice.keepWaiting;
      expect(await requests.open(benko), isA<RequestDropped>());
      expect(question.asked.single, contains('was stopped'));
      expect(session.source, kid);
      expect(requests.status, isNull);
    });

    test(
      'a copy saved on the way out is said once the chapter is open',
      () async {
        await freezeKid();
        question.answer = DraftChoice.saveACopy;
        expect(await requests.open(benko), isA<RequestDone>());
        expect(session.source, benko);
        expect(requests.status, 'Saved a copy as Main copy.pgn');
        expect(
          store.documents.keys.map((ref) => ref.path),
          contains('/repertoires/KID/Main copy.pgn'),
        );
      },
    );

    test('an open a later one overtook drops without a word', () async {
      store.hold = true;
      final first = requests.open(kid);
      final second = requests.open(benko);
      await pumpEventQueue();
      store.releaseAll();
      expect(await first, isA<RequestDropped>());
      expect(await second, isA<RequestDone>());
      expect(session.source, benko);
      expect(requests.status, isNull);
    });
  });

  group('the side question', () {
    setUp(() {
      store.documents[benko] = Opened(unsaid, scriptedRevision(unsaid));
    });

    test(
      'a chapter that does not say is asked once and the answer kept',
      () async {
        input.side = Side.black;
        await requests.open(benko);
        await pumpEventQueue();
        expect(input.sidesAsked, ['Main']);
        expect(session.chapter?.side, Side.black);
        expect(session.chapter?.sideStated, isTrue);
      },
    );

    test('a chapter that says is not asked', () async {
      await requests.open(kid);
      await pumpEventQueue();
      expect(input.sidesAsked, isEmpty);
    });

    test('dismissing it leaves the file as it was', () async {
      await requests.open(benko);
      await pumpEventQueue();
      expect(input.sidesAsked, ['Main']);
      expect(session.chapter?.sideStated, isFalse);
    });

    test(
      'an answer that comes after another chapter opened is dropped',
      () async {
        final answer = input.holdSide = Completer<Side?>();
        await requests.open(benko);
        await requests.open(kid);
        answer.complete(Side.white);
        await pumpEventQueue();
        expect(session.source, kid);
        expect(session.chapter?.side, Side.black, reason: 'KID stays Black');
      },
    );
  });

  group('new repertoires', () {
    test('the clipboard becomes a repertoire, opened in the builder', () async {
      requests.switchTo(Mode.study);
      input.clipboardText = pasted;
      expect(await requests.pasteRepertoire(), isA<RequestDone>());
      expect(requests.mode, Mode.repertoires);
      expect(session.source?.path, '/repertoires/Pasted repertoire/Main.pgn');
    });

    test('an empty clipboard is refused and writes nothing', () async {
      input.clipboardText = '  ';
      final result = await requests.pasteRepertoire();
      expect(
        (result as RequestRefused).sentence,
        'Nothing to paste: copy a PGN first.',
      );
      expect(store.creates, isEmpty);
      expect(session.source, isNull);
    });

    test('a clipboard with no moves is refused in plain English', () async {
      input.clipboardText = 'just words';
      final result = await requests.pasteRepertoire();
      expect(
        (result as RequestRefused).sentence,
        'That PGN has no moves to train.',
      );
      expect(
        store.documents.keys.map((ref) => ref.path),
        isNot(contains(contains('Pasted'))),
      );
    });

    test('a closed file dialog imports nothing', () async {
      expect(await requests.importFile(), isA<RequestDropped>());
      expect(requests.status, isNull);
    });

    test('a file that cannot be read is said in a sentence', () async {
      libraryPicker.answer = '/downloads/gone.pgn';
      final result = await requests.openPgnFile();
      expect((result as RequestRefused).sentence, 'Could not read that file.');
    });
  });

  group('files in the viewer', () {
    final games = collectionRef('games');

    setUp(() {
      store.documents[games] = Opened(
        threeGameFile,
        scriptedRevision(threeGameFile),
      );
    });

    test(
      'Open PGN file outside the builder reads the file in the viewer',
      () async {
        requests.switchTo(Mode.study);
        viewerPicker.answer = games.path;
        expect(await requests.openPgnFile(), isA<RequestDone>());
        expect(requests.mode, Mode.pgnViewer);
        expect(session.source, games);
        expect(session.game, 0);
        expect(viewer.file, games);
        expect(recent.saved.last, [games.path]);
      },
    );

    test(
      'a recent file opens on its first game, whichever mode asked',
      () async {
        expect(await requests.openFile(games), isA<RequestDone>());
        expect(requests.mode, Mode.pgnViewer);
        expect(session.game, 0);
        expect(viewer.file, games);
      },
    );

    test('a file that could not be read is not remembered', () async {
      store.documents.remove(games);
      final result = await requests.openFile(games);
      expect(result, isA<RequestRefused>());
      expect(recent.saved, isEmpty);
    });

    test('Close file takes it off the board', () async {
      await requests.openFile(games);
      expect(await requests.closeFile(), isA<RequestDone>());
      expect(session.source, isNull);
      expect(viewer.file, isNull);
    });

    test('Close file with nothing open does nothing', () async {
      expect(await requests.closeFile(), isA<RequestDropped>());
      expect(question.asked, isEmpty);
    });

    test('Close file over a draft the user stays with keeps it', () async {
      await freezeKid();
      question.answer = DraftChoice.keepWaiting;
      expect(await requests.closeFile(), isA<RequestDropped>());
      expect(session.source, kid);
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
        await requests.open(kid);
        session.forward();
        final ply = explorer.ply;
        expect(ply, greaterThan(0));
        expect(await requests.openExplorerGame(game), isA<RequestDone>());
        expect(requests.mode, Mode.pgnViewer);
        expect(session.source?.path, contains('/explorer games/'));
        expect(session.game, 0);
        expect(session.cursor, NodePath.of(List.filled(ply, 0)));
        expect(viewer.file, session.source);
      },
    );

    test('that could not be fetched is refused and nothing moves', () async {
      await requests.open(kid);
      lichess.pgn = null;
      final result = await requests.openExplorerGame(game);
      expect((result as RequestRefused).sentence, 'Could not fetch that game.');
      expect(requests.status, 'Could not fetch that game.');
      expect(requests.mode, Mode.repertoires);
      expect(session.source, kid);
    });

    test('is not opened over a draft the user stays with', () async {
      await freezeKid();
      question.answer = DraftChoice.keepWaiting;
      expect(await requests.openExplorerGame(game), isA<RequestDropped>());
      expect(session.source, kid);
    });
  });

  group('mode and status', () {
    test('switching to the study list reads it again', () async {
      final before = studyFiles.listings;
      var notified = 0;
      requests.addListener(() => notified++);
      requests.switchTo(Mode.study);
      await pumpEventQueue();
      expect(requests.mode, Mode.study);
      expect(studyFiles.listings, before + 1);
      requests.switchTo(Mode.study);
      expect(notified, 1, reason: 'the same mode is not a change');
    });

    test('say puts a sentence in the bar and takes it out', () {
      requests.say('Could not save a copy: disk full');
      expect(requests.status, 'Could not save a copy: disk full');
      requests.say(null);
      expect(requests.status, isNull);
    });
  });
}

/// The question put before a document is left: it records what it was
/// asked and answers what the test set.
final class _Question implements DraftQuestion {
  DraftChoice? answer;
  final asked = <String>[];

  @override
  Future<DraftChoice?> put(DraftPrompt prompt) {
    asked.add(prompt.body);
    return Future<DraftChoice?>.value(answer);
  }

  @override
  void withdraw() {}
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
