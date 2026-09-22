import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/app/shell.dart';
import 'package:chess_auto_prep/v2/app/window_input.dart';
import 'package:chess_auto_prep/v2/app/workspace_requests.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/features/library/chapter_outline.dart';
import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/features/pgn_viewer/pgn_viewer.dart';
import 'package:chess_auto_prep/v2/features/study/studies.dart';
import 'package:chess_auto_prep/v2/features/tactics/puzzle_trainer.dart';
import 'package:chess_auto_prep/v2/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/v2/net/lichess_studies.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/features/trainer/scope_reader.dart';
import 'package:chess_auto_prep/v2/features/trainer/trainer.dart';
import 'package:chess_auto_prep/v2/workspace/explorer.dart';
import 'package:chess_auto_prep/v2/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/v2/workspace/game_fetcher.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';
import 'library_fixture.dart';
import 'replies_fixture.dart';
import 'scripted_explorer.dart';
import 'scripted_progress.dart';
import 'scripted_files.dart';
import 'scripted_policy.dart';
import 'scripted_store.dart';
import 'study_fixture.dart';
import 'tactics_fixture.dart';
import 'viewer_fixture.dart';

/// KID/Main: a Black chapter of two lines.
final kidMain = ref('KID', 'Main');

/// benko/Main: an empty White chapter.
final benkoMain = ref('benko', 'Main');

/// Every owner the window is built from, as `app.dart` wires them, over a
/// scripted store holding [kidMain] and [benkoMain]. Nothing reaches a real
/// file, an engine or the network; the leave question and the file dialogs
/// answer what the test sets.
final class WindowFixture {
  /// [input] is the window the requests read from; by default the real
  /// dialogs over [navigator], for tests that pump [Shell].
  WindowFixture({WindowInput? input}) {
    session = DocumentSession(store, saver);
    library = libraryOver(
      ScriptedFiles(
        listing: Repertoires([
          folder('benko', ['Main']),
          folder('KID', ['Main']),
        ]),
      ),
      store,
      session,
      saver,
      picker: libraryPicker,
    );
    outline = ChapterOutline(library: library, session: session);
    viewer = PgnViewer(
      recent: recent,
      picker: viewerPicker,
      import: ScriptedImport(),
      settings: settings,
      session: session,
      collections: collectionsRoot,
    );
    _workspace();
    requests = WorkspaceRequests(
      session: session,
      library: library,
      studies: studies,
      viewer: viewer,
      games: games,
      leaving: _leaving(),
      input: input ?? DialogInput(navigator),
    );
    tactics = TacticsSet(
      documents: store,
      session: session,
      settings: settings,
      ref: tacticsRef,
      now: () => tacticsToday,
    );
    trainer = PuzzleTrainer(
      set: tactics,
      session: session,
      analysis: analysis,
      settings: settings,
      open: (set, game) async =>
          await requests.open(set, game: game) is RequestDone,
      now: () => tacticsToday,
    );
  }

  final store = ScriptedDocumentStore()
    ..documents[kidMain] = Opened(blackChapter, scriptedRevision(blackChapter))
    ..documents[benkoMain] = Opened(
      '// Color: White\n',
      scriptedRevision('// Color: White\n'),
    )
    ..documents[tacticsRef] = Opened(tacticsSet, scriptedRevision(tacticsSet));
  late final saver = DocumentSaver(store, delay: Duration.zero);
  late final DocumentSession session;

  /// What the library's file dialog answers.
  final libraryPicker = ScriptedPicker();
  late final Library library;
  late final ChapterOutline outline;
  final studyFiles = ScriptedStudyFiles();
  late final Studies studies;

  /// What the viewer's file dialog answers, and its recent list.
  final viewerPicker = ScriptedPicker();
  final recent = ScriptedRecentFiles();

  // In memory only, so it can be made once and disposed with the rest.
  final settings = SettingsStore();
  late final PgnViewer viewer;
  late final EngineAnalysis analysis;
  late final FillGaps fill;
  late final RepliesFixture replies;
  final lichess = ScriptedExplorerApi();
  late final Explorer explorer;
  late final GameFetcher games;
  final progress = ScriptedProgress();
  late final Trainer lineTrainer;

  /// The question before a document is left, answering [DraftQuestion]'s
  /// [ScriptedDraftQuestion.answer].
  final question = ScriptedDraftQuestion();
  late final WorkspaceRequests requests;
  late final TacticsSet tactics;
  late final PuzzleTrainer trainer;
  final navigator = GlobalKey<NavigatorState>();

  /// The owners of the workspace pane, none with an engine behind it.
  void _workspace() {
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
    analysis = EngineAnalysis(
      session,
      () async => const StartFailed('no engine in this test'),
    );
    fill = FillGaps(
      session: session,
      analysis: analysis,
      documents: store,
      tools: (_) async => const FillUnavailable('no engine in this test'),
    );
    replies = RepliesFixture(
      session,
      policy: const NoOpinion(),
      settings: settings,
    );
    explorer = explorerOver(session, settings: settings, lichess: lichess);
    games = gamesOver(store, lichess: lichess);
    lineTrainer = Trainer(
      session: session,
      chapters: ScopeReader(files: ScriptedFiles(), documents: store),
      files: progress,
      analysis: analysis,
      time: (now: DateTime.now, jitter: () => 0),
    );
  }

  /// A copy on the way out is written beside the chapter as `Main copy`.
  ExitGuard _leaving() => ExitGuard(
    saver: saver,
    question: question,
    saveCopy: () async {
      final written = await session.copyAside('Main copy');
      return written is CopySaved ? written.name : null;
    },
    wait: const Duration(milliseconds: 20),
  );

  /// The window over these owners, the library listed and both
  /// repertoires' rows opened, since the chapters are what tests click.
  Future<void> pumpShell(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: darkTheme(),
        home: Shell(
          requests: requests,
          library: library,
          studies: studies,
          viewer: viewer,
          settings: settings,
          settingRows: () => const [],
          settingsAlso: settings,
          outline: outline,
          session: session,
          saver: saver,
          analysis: analysis,
          replies: replies.replies,
          gaps: replies.gaps,
          explorer: explorer,
          games: games,
          fill: fill,
          tactics: tactics,
          trainer: trainer,
          lineTrainer: lineTrainer,
        ),
      ),
    );
    await library.refresh();
    await tester.pumpAndSettle();
    await tester.tap(find.text('benko'));
    await tester.tap(find.text('KID'));
    await tester.pumpAndSettle();
  }

  void dispose() {
    lineTrainer.dispose();
    tactics.dispose();
    requests.dispose();
    trainer.dispose();
    games.dispose();
    explorer.dispose();
    replies.dispose();
    viewer.dispose();
    settings.dispose();
    outline.dispose();
    fill.dispose();
    analysis.dispose();
    studies.dispose();
    library.dispose();
    session.dispose();
    saver.dispose();
  }
}

/// The question put before a document is left: it records what it was
/// asked and answers what the test set.
final class ScriptedDraftQuestion implements DraftQuestion {
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
