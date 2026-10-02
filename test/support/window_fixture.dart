import 'package:chess_auto_prep/storage/viewer_drafts.dart';
import 'package:chess_auto_prep/storage/viewer_places.dart';
import 'package:chess_auto_prep/storage/tournaments.dart';
import 'package:chess_auto_prep/features/tournaments/game_runner.dart';
import 'dart:async';

import 'package:chess_auto_prep/app/environment.dart';
import 'package:chess_auto_prep/app/app_parts.dart';
import 'package:chess_auto_prep/app/exit_guard.dart';
import 'package:chess_auto_prep/app/shell.dart';
import 'package:chess_auto_prep/app/window_input.dart';
import 'package:chess_auto_prep/app/workspace_requests.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/maia/move_policy.dart';
import 'package:chess_auto_prep/features/bughouse/archive_moves.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/features/bughouse/table_search.dart';
import 'package:chess_auto_prep/features/library/chapter_outline.dart';
import 'package:chess_auto_prep/features/my_games/game_book.dart';
import 'package:chess_auto_prep/features/library/library.dart';
import 'package:chess_auto_prep/features/pgn_viewer/pgn_viewer.dart';
import 'package:chess_auto_prep/features/study/studies.dart';
import 'package:chess_auto_prep/features/tactics/puzzle_trainer.dart';
import 'package:chess_auto_prep/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/net/lichess_studies.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/features/tactics/my_games.dart';
import 'package:chess_auto_prep/storage/my_games_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/ui/navigation_pages.dart';
import 'package:chess_auto_prep/workspace/document_saver.dart';
import 'package:chess_auto_prep/workspace/document_session.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/features/trainer/trainer.dart';
import 'package:chess_auto_prep/workspace/repertoire_shelf.dart';
import 'package:chess_auto_prep/workspace/repertoire_tree.dart';
import 'package:chess_auto_prep/workspace/explorer.dart';
import 'package:chess_auto_prep/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/workspace/game_fetcher.dart';
import 'package:chess_auto_prep/workspace/session_results.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';
import 'scripted_bughouse.dart';
import 'scripted_explorer.dart';
import 'scripted_progress.dart';
import 'scripted_files.dart';
import 'scripted_login.dart';
import 'scripted_policy.dart';
import 'my_games_fixture.dart';
import 'scripted_store.dart';
import 'study_fixture.dart';
import 'tactics_fixture.dart';
import 'viewer_fixture.dart';
import 'package:chess_auto_prep/storage/book_file.dart';
import 'package:chess_auto_prep/storage/book_list.dart';

/// KID/Main: a Black chapter of two lines.
final kidMain = ref('KID', 'Main');

/// benko/Main: an empty White chapter.
final benkoMain = ref('benko', 'Main');

/// The app as [AppParts] puts it together, over a scripted environment:
/// a store holding [kidMain], [benkoMain] and the tactics set, and fakes for
/// every file dialog, site and engine. Nothing reaches a real file, an
/// engine or the network; the leave question and the dialogs answer what
/// the test sets. The wiring is the app's own, so a window test checks how
/// the app is put together, not a copy of it.
final class WindowFixture {
  /// [input] is the window the requests read from; by default the real
  /// dialogs over [navigator], for tests that pump [Shell]. [settings] is a
  /// store over a real folder, for a test of how they are read; by default
  /// they are in memory. [launchEngine] starts the Stockfish the workspace
  /// and the fill ask for; by default none starts. [players] is the player
  /// directory; by default in memory.
  WindowFixture({
    WindowInput? input,
    SettingsStore? settings,
    EngineLauncher? launchEngine,
    this.tournaments,
    this.viewerPlaces,
    this.viewerDrafts,
    this.launchTournament,
    PlayerStore? players,
    this.exitWait = const Duration(milliseconds: 20),
    MovePolicy maia = const NoOpinion(),
  }) : _input = input,
       _settings = settings,
       _launchEngine = launchEngine,
       _players = players,
       _maia = maia;

  final TournamentStore? tournaments;
  final ViewerPlaces? viewerPlaces;

  /// Where held viewer edits are checkpointed; none by default.
  final ViewerDrafts? viewerDrafts;

  /// How long closing waits on writes before it asks; short, so a test of
  /// the question does not wait long for it.
  final Duration exitWait;
  final TournamentLauncher? launchTournament;
  final WindowInput? _input;
  final SettingsStore? _settings;
  final EngineLauncher? _launchEngine;
  final PlayerStore? _players;
  final MovePolicy _maia;
  final navigator = GlobalKey<NavigatorState>();

  /// The question before a document is left, answering what the test sets
  /// in [ScriptedDraftQuestion.answer].
  final question = ScriptedDraftQuestion();

  /// The Bughouse lab's engine, book and archive.
  final bughouse = ScriptedBughouse();

  late final parts = AppParts(
    _environment(bughouse),
    question: question,
    input: _input ?? DialogInput(navigator),
    copyOnLeave: _copyAside,
  );

  /// A copy on the way out is written beside the chapter as `Main copy`.
  static Future<CopyResult?> _copyAside(DocumentSession session) =>
      session.copyAside('Main copy');

  /// What the window was asked, in order: true for into full screen.
  final fullScreenAsked = <bool>[];

  late final _store = ScriptedDocumentStore()
    ..documents[kidMain] = Opened(blackChapter, scriptedRevision(blackChapter))
    ..documents[benkoMain] = Opened(
      '// Color: White\n',
      scriptedRevision('// Color: White\n'),
    )
    ..documents[tacticsRef] = Opened(tacticsSet, scriptedRevision(tacticsSet));

  AppEnvironment _environment(ScriptedBughouse bughouse) {
    final lichess = ScriptedExplorerApi();
    return AppEnvironment(
      tournaments: tournaments,
      launchTournament: launchTournament,
      folders: (
        repertoires: '/repertoires',
        studies: studiesRoot,
        collections: collectionsRoot,
        gamesLibrary: '/games_library',
        tacticsSet: tacticsRef,
      ),
      store: _store,
      // In memory unless the test gave a folder; disposed with the rest.
      settings: _settings ?? SettingsStore(),
      // The two repertoires the library lists, each of one chapter.
      chapterFiles: ScriptedFiles(
        listing: Repertoires([
          folder('benko', ['Main']),
          folder('KID', ['Main']),
        ]),
      ),
      studyFiles: ScriptedStudyFiles(),
      libraryPicker: ScriptedPicker(),
      viewerPicker: ScriptedPicker(),
      recentFiles: ScriptedRecentFiles(),
      viewerPlaces: viewerPlaces,
      viewerDrafts: viewerDrafts,
      fileImport: ScriptedImport(),
      lichessLogin: ScriptedLogin(),
      readAccount: () async => null,
      writeAccount: (_) async => true,
      lichessStudies: ScriptedLichess(
        const StudyNotFetched(StudyFetchProblem.unreachable),
      ),
      lichessExplorer: lichess,
      masterBook: ScriptedBook(),
      gameStore: ScriptedGameStore(),
      gameSites: const [],
      // The usernames, in memory: none until a test sets them.
      accounts: MemoryAccounts(),
      // One book in use, with both repertoires in it.
      books: MemoryBooks(
        const BookList(
          books: [
            Book(id: 'test', name: 'Test book', repertoires: {'benko', 'KID'}),
          ],
          active: 'test',
        ),
      ),
      progressFiles: ScriptedProgress(),
      players: _players,
      olderAnalyzed: () async => {},
      maia: _maia,
      launchEngine:
          _launchEngine ??
          ({required cores, required memoryMb}) async =>
              const StartFailed('no engine in this test'),
      stopEngines: () async {},
      evalCache: () => throw StateError('no eval cache in this test'),
      keepTree: (_, _, {required runId}) async {},
      setFullScreen: (on) async => fullScreenAsked.add(on),
      bughouse: bughouse.outside,
      now: () => tacticsToday,
      saveDelay: Duration.zero,
      explorerDelay: Duration.zero,
      exitWait: exitWait,
    );
  }

  AppEnvironment get _env => parts.env;

  ScriptedDocumentStore get store => _store;
  ScriptedFiles get chapterFiles => _env.chapterFiles as ScriptedFiles;
  ScriptedStudyFiles get studyFiles => _env.studyFiles as ScriptedStudyFiles;

  /// What the library's and the viewer's file dialogs answer.
  ScriptedPicker get libraryPicker => _env.libraryPicker as ScriptedPicker;
  ScriptedPicker get viewerPicker => _env.viewerPicker as ScriptedPicker;
  ScriptedRecentFiles get recent => _env.recentFiles as ScriptedRecentFiles;
  ScriptedExplorerApi get lichess =>
      _env.lichessExplorer as ScriptedExplorerApi;
  MemoryAccounts get accounts => _env.accounts as MemoryAccounts;
  ScriptedProgress get progress => _env.progressFiles as ScriptedProgress;

  SettingsStore get settings => parts.settings;
  DocumentSaver get saver => parts.saver;
  DocumentSession get session => parts.session;
  WorkspaceRequests get requests => parts.requests;

  Library get library => parts.documents.library;
  ChapterOutline get outline => parts.documents.outline;
  Studies get studies => parts.documents.studies;
  PgnViewer get viewer => parts.documents.viewer;

  EngineAnalysis get analysis => parts.workspace.analysis;
  Explorer get explorer => parts.workspace.explorer;
  GameFetcher get games => parts.workspace.games;
  FillGaps get fill => parts.workspace.fill;
  RepertoireTree get tree => parts.workspace.tree;
  RepertoireShelf get shelf => parts.workspace.shelf;

  TacticsSet get tactics => parts.training.tactics;
  PuzzleTrainer get trainer => parts.training.puzzles;
  Trainer get lineTrainer => parts.training.lines;
  MyGames get myGames => parts.training.myGames;
  GameBook get book => parts.training.book;
  GamesCache get gamesCache => parts.gamesCache;

  BughouseLab get lab => parts.labs.lab;
  TableSearch get tableSearch => parts.labs.search;
  ArchiveMoves get archive => parts.labs.archive;

  /// The window over these parts, the library listed and both
  /// repertoires' rows opened, since the chapters are what tests click.
  Future<void> pumpShell(WidgetTester tester) async {
    // The app reads the books as it starts; the rest of the start (the
    // engine, the settings file) the tests leave out.
    unawaited(parts.books.load());
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: darkTheme(),
        home: Shell(
          requests: parts.requests,
          workspace: parts.workspace,
          documents: parts.documents,
          training: parts.training,
          labs: parts.labs,
          players: parts.players,
          databases: parts.databases,
          tournaments: parts.tournaments,
          fullScreen: parts.fullScreen,
          settingRows: () => const [],
          settingsAlso: settings,
        ),
      ),
    );
    await library.refresh();
    await parts.labs.offer(parts.env.bughouse.bundled);
    await tester.pumpAndSettle();
    // An already-open chapter selects Chapters in compact navigation.
    // Reveal the repertoire list before opening its fixture folders.
    final navigation = find.byType(NavigationPages);
    if (navigation.evaluate().isNotEmpty) {
      await tester.tap(
        find.descendant(of: navigation, matching: find.text('Repertoires')),
      );
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('benko'));
    await tester.tap(find.text('KID'));
    await tester.pumpAndSettle();
  }

  void dispose() => parts.dispose();
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
