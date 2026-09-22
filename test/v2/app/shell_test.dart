import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:chess_auto_prep/v2/app/shell.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/features/library/chapter_outline.dart';
import 'package:chess_auto_prep/v2/net/lichess_studies.dart';
import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/features/library/library_panel.dart';
import 'package:chess_auto_prep/v2/features/library/outline_panel.dart';
import 'package:chess_auto_prep/v2/features/pgn_viewer/pgn_viewer.dart';
import 'package:chess_auto_prep/v2/features/study/studies.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/recent_pgn_files.dart';
import 'package:chess_auto_prep/v2/workspace/save_state.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_answers.dart';
import 'package:chess_auto_prep/v2/workspace/replies.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_policy.dart';
import '../support/fixtures.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/study_fixture.dart';
import '../support/viewer_fixture.dart';

void main() {
  final kid = ref('KID', 'Main');
  final benko = ref('benko', 'Main');

  /// Both columns list a chapter called Main once one is open, so a row is
  /// looked for in the column it belongs to.
  Finder inLibrary(Finder row) =>
      find.descendant(of: find.byType(LibraryPanel), matching: row);
  Finder inOutline(Finder row) =>
      find.descendant(of: find.byType(OutlinePanel), matching: row);
  late ScriptedFiles files;
  late ScriptedDocumentStore store;
  late Library library;
  late Studies studies;
  late DocumentSaver saver;
  late DocumentSession session;
  late EngineAnalysis analysis;
  late Replies replies;
  late ChapterOutline outline;
  late PgnViewer viewer;
  // In memory only, so it can be made once and disposed with the rest.
  late SettingsStore settings;
  late ScriptedRecentFiles recent;
  late ScriptedPicker picker;
  late _Question question;
  late ExitGuard leaving;

  setUp(() {
    files = ScriptedFiles(
      listing: Repertoires([
        folder('benko', ['Main']),
        folder('KID', ['Main']),
      ]),
    );
    store = ScriptedDocumentStore()
      ..documents[kid] = Opened(blackChapter, scriptedRevision(blackChapter))
      ..documents[benko] = Opened(
        '// Color: White\n',
        scriptedRevision('// Color: White\n'),
      );
    saver = DocumentSaver(store, delay: Duration.zero);
    session = DocumentSession(store, saver);
    picker = ScriptedPicker();
    library = Library(
      files: files,
      documents: store,
      session: session,
      saver: saver,
      picker: picker,
      root: '/repertoires',
    );
    outline = ChapterOutline(library: library, session: session);
    recent = ScriptedRecentFiles();
    viewer = viewerFor(session, recent);
    studies = Studies(
      files: ScriptedStudyFiles(),
      documents: store,
      session: session,
      saver: saver,
      lichess: ScriptedLichess(
        const StudyNotFetched(StudyFetchProblem.unreachable),
      ),
      root: studiesRoot,
    );
    analysis = EngineAnalysis(
      session,
      () async => const StartFailed('no engine in this test'),
    );
    (question, settings) = (_Question(), SettingsStore());
    leaving = ExitGuard(
      saver: saver,
      question: question,
      saveCopy: () async {
        final written = await session.copyAside('Main copy');
        return written is CopySaved ? written.name : null;
      },
      wait: const Duration(milliseconds: 20),
    );
  });

  tearDown(() {
    viewer.dispose();
    settings.dispose();
    outline.dispose();
    analysis.dispose();
    studies.dispose();
    library.dispose();
    session.dispose();
    saver.dispose();
  });

  Future<void> pump(WidgetTester tester) async {
    replies = Replies(
      session: session,
      policy: const NoOpinion(),
      settings: settings,
      answers: RepertoireAnswers(
        files: ScriptedFiles(),
        documents: ScriptedDocumentStore(),
      ),
    );
    addTearDown(replies.dispose);
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Shell(
          library: library,
          studies: studies,
          viewer: viewer,
          settings: settings,
          settingRows: () => const [],
          outline: outline,
          session: session,
          saver: saver,
          analysis: analysis,
          replies: replies,
          leaving: leaving,
        ),
      ),
    );
    await library.refresh();
    await tester.pumpAndSettle();
    // The rows start closed; the chapters are what this test clicks.
    await tester.tap(find.text('benko'));
    await tester.tap(find.text('KID'));
    await tester.pumpAndSettle();
  }

  testWidgets('opening a chapter puts it in the workspace', (tester) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last);
    await tester.pump();
    expect(session.source, kid);
    expect(session.chapter?.gameCount, 2);
    expect(
      find.text('Black · 2 lines, 1 from another position'),
      findsOneWidget,
    );
  });

  testWidgets('the later of two clicks wins, whichever read finishes first', (
    tester,
  ) async {
    await pump(tester);
    store.hold = true;
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.tap(inLibrary(find.text('Main')).first); // benko
    expect(store.waiting, 2);
    store.releaseAll(); // KID's read answers before benko's
    await tester.pump();
    expect(session.source, benko);
    // The stale KID answer must not have replaced benko.
    await tester.pump();
    expect(session.source, benko);
  });

  testWidgets('a chapter that vanished is reported, not opened', (
    tester,
  ) async {
    await pump(tester);
    store.documents.clear();
    await tester.tap(inLibrary(find.text('Main')).last);
    await tester.pump();
    expect(session.chapter, isNull);
    expect(find.text('Main is no longer on disk'), findsOneWidget);
  });
  testWidgets('another chapter is not opened over a frozen document until '
      'the user says so', (tester) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    store.saves.add(
      const SaveRefused('game 3 would change but the edit was to game 1'),
    );
    session.setComment(NodePath.of([0]), 'frozen words');
    await tester.pumpAndSettle();
    expect(saver.state, isA<SaveStopped>());

    question.answer = DraftChoice.keepWaiting;
    await tester.tap(inLibrary(find.text('Main')).first); // benko
    await tester.pumpAndSettle();
    expect(question.asked.single, contains('was stopped'));
    expect(session.source, kid, reason: 'nothing opened over the words');
    expect(session.commentAt(NodePath.of([0])), contains('frozen words'));
  });

  testWidgets('leaving a frozen document anyway is logged', (tester) async {
    final entries = <LogEntry>[];
    void collect(LogEntry entry) => entries.add(entry);
    log.install(collect);
    addTearDown(() => log.remove(collect));
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    store.saves.add(const SaveRefused('game 3 would change'));
    session.setComment(NodePath.of([0]), 'frozen words');
    await tester.pumpAndSettle();

    question.answer = DraftChoice.closeAnyway;
    await tester.tap(inLibrary(find.text('Main')).first); // benko
    await tester.pumpAndSettle();
    expect(session.source, benko);
    expect(
      entries
          .where((entry) => entry.level == LogLevel.warning)
          .map((entry) => entry.action),
      contains(contains('leave this document with unsaved words')),
    );
  });
  testWidgets('clicking the chapter that is already open asks nothing', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    store.saves.add(const SaveRefused('game 3 would change'));
    session.setComment(NodePath.of([0]), 'frozen words');
    await tester.pumpAndSettle();
    question.asked.clear();

    await tester.tap(inLibrary(find.text('Main')).last); // KID again
    await tester.pumpAndSettle();
    expect(question.asked, isEmpty);
    expect(session.source, kid);
  });

  testWidgets('saving a copy on the way out says where the words went', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last); // KID
    await tester.pumpAndSettle();
    store.saves.add(const SaveRefused('game 3 would change'));
    session.setComment(NodePath.of([0]), 'frozen words');
    await tester.pumpAndSettle();

    question.answer = DraftChoice.saveACopy;
    await tester.tap(inLibrary(find.text('Main')).first); // benko
    await tester.pumpAndSettle();
    expect(session.source, benko, reason: 'the click still went through');
    expect(find.text('Saved a copy as Main copy.pgn'), findsOneWidget);
    expect(
      store.documents.keys.map((ref) => ref.path),
      contains('/repertoires/KID/Main copy.pgn'),
    );
  });

  testWidgets('the PGN Viewer opens a recent file on its first game and '
      'walks its games on the same board', (tester) async {
    final games = collectionRef('games');
    store.documents[games] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    recent.listing = RecentFilesListed([games.path]);
    await pump(tester);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PGN Viewer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('games.pgn'));
    await tester.pumpAndSettle();
    expect(session.source, games);
    expect(session.game, 0);
    expect(find.text('of 3'), findsOneWidget, reason: 'under the board');
    expect(find.byType(OutlinePanel), findsNothing);
    // The header names the game rather than counting lines.
    // Once in the list, once as the heading.
    expect(find.text('Carlsen, Magnus – Nakamura, Hikaru'), findsNWidgets(2));
    expect(find.text('1-0 · Tata Steel · 2024'), findsOneWidget);
    await tester.tap(find.byTooltip('Next game (↓)'));
    await tester.pumpAndSettle();
    expect(session.game, 1);
    expect(find.text('Ding, Liren – Giri, Anish'), findsWidgets);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close file'));
    await tester.pumpAndSettle();
    expect(session.source, isNull);
    expect(find.text('Recent files'), findsOneWidget);
  });

  testWidgets('Ctrl+Z reaches the document from the outline column', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last);
    await tester.pumpAndSettle();

    // Working in another column leaves the focus there: on the row that was
    // clicked, or on the menu button beside it, and not on the board.
    final inRow = find.descendant(
      of: find.byType(OutlinePanel),
      matching: find.byType(Text),
    );
    Focus.of(tester.element(inRow.last)).requestFocus();
    await tester.pumpAndSettle();
    expect(
      find.ancestor(
        of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget),
        matching: find.byType(OutlinePanel),
      ),
      findsOneWidget,
      reason: 'the focus is on a row of the outline column',
    );

    await tester.tap(inOutline(find.byTooltip('Actions')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename line…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Closed');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(textOf(store, kid), contains('[Event "Closed"]'));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(textOf(store, kid), isNot(contains('[Event "Closed"]')));
  });

  testWidgets('the Actions menu closes and shows the Replies tab', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last);
    await tester.pumpAndSettle();
    expect(find.text('Replies'), findsOneWidget);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    expect(find.text('Next tab'), findsOneWidget);
    expect(find.text('Ctrl+Tab'), findsOneWidget);
    await tester.tap(find.text('Close Replies'));
    await tester.pumpAndSettle();
    expect(find.text('Replies'), findsNothing);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show Replies'));
    await tester.pumpAndSettle();
    expect(find.text('Replies'), findsOneWidget);
    expect(find.text('Next gap'), findsOneWidget, reason: 'brought up');
  });

  const pasted = '[Event "x"]\n[Result "*"]\n\n1. e4 e5 (1... c5) *\n';

  /// What the clipboard answers when the shell asks for text.
  void clipboardHolds(WidgetTester tester, String? text) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => switch (call.method) {
        'Clipboard.getData' => text == null ? null : {'text': text},
        'Clipboard.hasStrings' => {'value': text != null},
        _ => null,
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  Future<void> pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('the builder offers Open PGN file and Paste PGN, the viewer '
      'Open and Close file', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    expect(find.text('Open PGN file…'), findsOneWidget);
    expect(find.text('Paste PGN'), findsOneWidget);
    expect(find.text('Ctrl+V'), findsOneWidget);
    expect(find.text('Close file'), findsNothing);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repertoire builder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PGN Viewer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    // The viewer's own empty list offers the file dialog too.
    expect(find.text('Open PGN file…'), findsAtLeastNWidgets(1));
    expect(find.text('Paste PGN'), findsNothing);
    expect(find.text('Close file'), findsOneWidget);
  });

  testWidgets('Ctrl+V in the builder makes a repertoire of the clipboard and '
      'opens it, asking which side it is for', (tester) async {
    await pump(tester);
    clipboardHolds(tester, pasted);
    await pressCtrl(tester, LogicalKeyboardKey.keyV);
    expect(session.source?.path, '/repertoires/Pasted repertoire/Main.pgn');
    expect(session.chapter?.gameCount, 2, reason: 'the variation is a line');
    expect(
      store.documents.keys.map((ref) => ref.path),
      contains('/repertoires/Pasted repertoire/Main.pgn'),
    );
    expect(find.text('Which side is Main for?'), findsOneWidget);
  });

  testWidgets('Paste PGN in the Actions menu does the same', (tester) async {
    await pump(tester);
    clipboardHolds(tester, pasted);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste PGN'));
    await tester.pumpAndSettle();
    expect(session.source?.path, '/repertoires/Pasted repertoire/Main.pgn');
  });

  testWidgets('an empty clipboard says so and writes nothing', (tester) async {
    await pump(tester);
    clipboardHolds(tester, null);
    await pressCtrl(tester, LogicalKeyboardKey.keyV);
    expect(find.text('Nothing to paste: copy a PGN first.'), findsOneWidget);
    expect(session.source, isNull);
  });

  testWidgets('a clipboard with no moves is refused in plain English', (
    tester,
  ) async {
    await pump(tester);
    clipboardHolds(tester, 'just words');
    await pressCtrl(tester, LogicalKeyboardKey.keyV);
    expect(find.text('That PGN has no moves to train.'), findsOneWidget);
    expect(
      store.documents.keys.map((ref) => ref.path),
      isNot(contains(contains('Pasted'))),
    );
  });

  testWidgets('Ctrl+O in the builder imports the chosen file as a repertoire', (
    tester,
  ) async {
    await pump(tester);
    picker.answer = '/downloads/Italian.pgn';
    store.documents[const DocumentRef('/downloads/Italian.pgn')] = Opened(
      pasted,
      scriptedRevision(pasted),
      readOnly: 'outside Documents',
    );
    await pressCtrl(tester, LogicalKeyboardKey.keyO);
    expect(session.source?.path, '/repertoires/Italian/Main.pgn');
  });

  testWidgets('a file that cannot be read is said in a sentence', (
    tester,
  ) async {
    await pump(tester);
    picker.answer = '/downloads/gone.pgn';
    await pressCtrl(tester, LogicalKeyboardKey.keyO);
    expect(find.text('Could not read that file.'), findsOneWidget);
  });

  testWidgets('Actions sits beside the mode menu, at the left', (tester) async {
    await pump(tester);
    final mode = tester.getTopRight(find.text('Repertoire builder').first);
    final actions = tester.getTopLeft(find.text('Actions'));
    expect(actions.dx, greaterThan(mode.dx));
    expect(actions.dx, lessThan(paneMinWidth * 2));
  });

  testWidgets('the side is changed from Actions and written to the file', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).last);
    await tester.pumpAndSettle();
    expect(find.byType(SegmentedButton<Side>), findsNothing);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play as White'));
    await tester.pumpAndSettle();
    expect(session.chapter?.side, Side.white);
    expect(
      find.text('White · 2 lines, 1 from another position'),
      findsOneWidget,
    );
  });

  testWidgets('a chapter whose file does not say its side is asked once, '
      'and the answer is written down', (tester) async {
    const unsaid = '[Event "Open"]\n[Result "*"]\n\n1. e4 e5 *\n';
    store.documents[benko] = Opened(unsaid, scriptedRevision(unsaid));
    await pump(tester);
    await tester.tap(inLibrary(find.text('Main')).first);
    await tester.pumpAndSettle();
    expect(find.text('Which side is Main for?'), findsOneWidget);
    await tester.tap(find.text('Black'));
    await tester.pumpAndSettle();
    expect(find.text('Which side is Main for?'), findsNothing);
    expect(session.chapter?.side, Side.black);
    expect(session.chapter?.sideStated, isTrue);
    await saver.flush();
    expect(
      (store.documents[benko] as Opened).text,
      startsWith('// Color: Black\n'),
    );
    // The stated chapter is not asked.
    await tester.tap(inLibrary(find.text('Main')).last);
    await tester.pumpAndSettle();
    expect(find.text('Which side is Main for?'), findsNothing);
  });

  testWidgets('the list toggle sits at the edge of the pane, shown or not', (
    tester,
  ) async {
    await pump(tester);
    // Shown: `«` in the pane's own top right corner, not the top bar.
    final hide = find.byTooltip('Hide the list (Ctrl+B)');
    expect(hide, findsOneWidget);
    expect(find.byTooltip('Show the list (Ctrl+B)'), findsNothing);
    final corner = tester.getTopRight(hide);
    expect(corner.dx, closeTo(paneMinWidth, Space.l));
    expect(corner.dy, greaterThan(40));
    await tester.tap(hide);
    await tester.pumpAndSettle();
    // Hidden: `»` at the top bar's left, where the pane would begin.
    final show = find.byTooltip('Show the list (Ctrl+B)');
    expect(show, findsOneWidget);
    expect(hide, findsNothing);
    expect(tester.getTopLeft(show).dx, lessThan(Space.l));
    expect(find.text('Your repertoires'), findsNothing);
    await tester.tap(show);
    await tester.pumpAndSettle();
    expect(find.text('Your repertoires'), findsOneWidget);
  });
}

/// What the scripted store holds for [ref] now.
String textOf(ScriptedDocumentStore store, ChapterRef ref) =>
    switch (store.documents[ref]) {
      Opened(:final text) => text,
      _ => '',
    };

/// The question the shell puts before it leaves a document: it records what
/// it was asked and answers what the test set.
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
