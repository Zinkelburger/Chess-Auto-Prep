import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../chess/generation/tree_wire_v4.dart' show treeWireVersion;
import '../diagnostics/log.dart';
import '../engines/engine_supervisor.dart';
import '../engines/fixed_depth.dart';
import '../chess/tactics/game_ids.dart' show GameSite;
import '../features/library/chapter_outline.dart';
import '../features/my_games/game_book.dart';
import '../features/library/library.dart';
import '../features/pgn_viewer/pgn_viewer.dart';
import '../features/settings/setting_rows.dart';
import '../features/settings/lichess_account.dart';
import '../features/study/studies.dart';
import '../features/trainer/scope_reader.dart';
import '../features/trainer/trainer.dart';
import '../features/tactics/my_games.dart';
import '../features/tactics/puzzle_trainer.dart';
import '../features/tactics/set_additions.dart';
import '../features/tactics/tactics_set.dart';
import '../net/lichess_explorer.dart';
import '../net/lichess_login.dart';
import '../net/lichess_studies.dart';
import '../net/recent_games.dart';
import '../storage/atomic_write.dart';
import '../storage/chapter_files.dart';
import '../storage/eval_cache.dart';
import '../storage/lichess_token.dart';
import '../storage/master_book.dart';
import '../storage/my_accounts.dart';
import '../storage/my_games_files.dart';
import '../storage/pgn_file_import.dart';
import '../storage/pgn_file_picker.dart';
import '../storage/pgn_file_store.dart';
import '../storage/recent_pgn_files.dart';
import '../storage/settings_store.dart';
import '../storage/study_files.dart';
import '../storage/training_store.dart';
import '../ui/theme.dart';
import '../workspace/copy_name_dialog.dart';
import '../workspace/document_saver.dart';
import '../workspace/document_session.dart';
import '../workspace/session_results.dart';
import '../workspace/engine_analysis.dart';
import '../workspace/repertoire_shelf.dart';
import '../workspace/repertoire_tree.dart';
import '../workspace/explorer.dart';
import '../workspace/explorer_databases.dart';
import '../workspace/fill_gaps.dart';
import '../workspace/fill_sources.dart';
import '../workspace/repertoire_answers.dart';
import '../workspace/gap_hunt.dart';
import '../workspace/game_fetcher.dart';
import '../workspace/replies.dart';
import '../workspace/reply_model.dart';
import 'app_exit.dart';
import 'engine_launch.dart';
import 'maia_launch.dart';
import 'exit_guard.dart';
import 'open_folder.dart';
import 'shell.dart';
import 'window_input.dart';
import 'workspace_requests.dart';
import '../workspace/copy_aside.dart';

/// Builds the owners and hands them to the shell. This is the only place
/// that knows how the pieces fit together.
class ChessAutoPrepV2 extends StatefulWidget {
  const ChessAutoPrepV2({
    super.key,
    required this.documents,
    required this.support,
    required this.logFolder,
    required this.closeLog,
  });

  /// The user's Documents directory; repertoires live under it.
  final Directory documents;

  /// The app's own folder, where the engine is installed and the settings
  /// are kept.
  final Directory support;

  /// Where the log file is, for the settings page to open.
  final Directory logFolder;

  /// Flushes and closes the log file `main_v2` opened. Called on the way
  /// out, after the engines, so their last words reach the file.
  final Future<void> Function() closeLog;

  @override
  State<ChessAutoPrepV2> createState() => _ChessAutoPrepV2State();
}

class _ChessAutoPrepV2State extends State<ChessAutoPrepV2> {
  late final _repertoires = p.join(widget.documents.path, 'repertoires');
  late final _studyFolder = p.join(widget.documents.path, 'studies');
  late final _store = PgnFileStore(
    documents: widget.documents,
    support: widget.support,
  );
  late final _settings = SettingsStore(support: widget.support);
  late final _saver = DocumentSaver(_store);
  late final _session = DocumentSession(_store, _saver);
  late final Library _library = Library(
    files: _chapterFiles,
    writes: LibraryWrites(
      files: _chapterFiles,
      documents: _store,
      session: _session,
      saver: _saver,
      root: _repertoires,
    ),
    session: _session,
    picker: const NativePgnFilePicker(),
    root: _repertoires,
  );
  final _lichess = http.Client();
  late final _account = LichessAccountState(
    login: LichessLoginApi(_lichess, openBrowser: openInBrowser),
  );
  late final Studies _studies = Studies(
    files: StudyDirectory(Directory(_studyFolder)),
    documents: _store,
    session: _session,
    saver: _saver,
    lichess: LichessStudyApi(_lichess, token: readLichessToken),
    root: _studyFolder,
  );
  late final _collections = p.join(widget.documents.path, 'pgn_collections');
  late final _viewer = PgnViewer(
    recent: PreferencesRecentFiles(),
    picker: const NativePgnFilePicker(),
    import: NativePgnFileImport(
      documents: widget.documents.path,
      into: _collections,
    ),
    settings: _settings,
    session: _session,
    collections: _collections,
  );
  late final _outline = ChapterOutline(library: _library, session: _session);
  final _engines = EngineSupervisor();
  late final _analysis = EngineAnalysis(
    _session,
    () => launchStockfish(
      support: widget.support,
      engines: _engines,
      cores: _settings.value.engineCores,
      memoryMb: _settings.value.engineMemoryMb,
    ),
    multiPv: _settings.value.engineLines,
    elsewhere: _tree.board,
  );

  final _maia = MaiaLaunch();
  late final _chapterFiles = ChapterDirectory(Directory(_repertoires));
  late final _answers = RepertoireAnswers(
    files: _chapterFiles,
    documents: _store,
  );
  late final _replyModel = ReplyModel(policy: _maia, settings: _settings);
  late final _gaps = GapHunt(
    session: _session,
    model: _replyModel,
    settings: _settings,
    answers: _answers,
  );
  late final _replies = Replies(
    session: _session,
    model: _replyModel,
    settings: _settings,
    gaps: _gaps,
  );

  /// The old app's master database, in the same support folder, read as it
  /// is: TWIC is listed when the file is there.
  late final _book = SqliteMasterBook(
    p.join(widget.support.path, 'master_games.db'),
  );
  late final _databases = ExplorerDatabases(
    lichess: LichessExplorerApi(_lichess, token: readLichessToken),
    book: _book,
  );
  late final _explorer = Explorer(
    session: _session,
    settings: _settings,
    databases: _databases,
  );

  /// Every repertoire file, indexed by position once until it changes:
  /// the Tree tab and the book check read the same one.
  late final _shelf = RepertoireShelf(files: _chapterFiles, documents: _store);
  late final _tree = RepertoireTree(session: _session, shelf: _shelf);
  late final _games = GameFetcher(
    databases: _databases,
    documents: _store,
    collections: _collections,
  );

  final _dice = Random();
  late final _lineTrainer = Trainer(
    session: _session,
    chapters: ScopeReader(files: _chapterFiles, documents: _store),
    files: TrainingStore(widget.documents),
    analysis: _analysis,
    time: (now: DateTime.now, jitter: () => _dice.nextDouble() * 2 - 1),
  );

  /// The engine's verdicts, shared with the old app, opened the first time
  /// a fill needs them.
  late final _evalCache = EvalCacheOnDemand(widget.support);
  late final _fill = FillGaps(
    session: _session,
    analysis: _analysis,
    documents: _store,
    tools: _fillTools,
    keepTree: _keepTree,
  );

  /// A second Stockfish for the fill, with the pane's threads and table:
  /// the pane's own engine is paused for the run, so the machine is not
  /// shared, and quitting this one when the run ends costs nothing the pane
  /// has to rebuild.
  Future<FillToolsResult> _fillTools(FillRequest request) async {
    final start = await launchStockfish(
      support: widget.support,
      engines: _engines,
      cores: _settings.value.engineCores,
      memoryMb: _settings.value.engineMemoryMb,
    );
    return switch (start) {
      StartFailed(:final reason) => FillUnavailable(reason),
      Started(:final engine) => FillReady(
        evaluator: CachedEvaluator(
          FixedDepthEvaluator(engine, depth: fillEvalDepth),
          _evalCache.cache,
          depth: fillEvalDepth,
        ),
        policy: MaiaOpponent(_maia, elo: request.elo),
        release: engine.quit,
      ),
    };
  }

  /// The tree beside its chapter, where the old app keeps its own:
  /// `.cap-generation/<chapter>.pgn/<run>/tree.json`, create-only.
  Future<void> _keepTree(ChapterRef chapter, String tree) async {
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final folder = p.join(
      p.dirname(chapter.path),
      '.cap-generation',
      p.basename(chapter.path),
      'v2-$stamp',
    );
    await Directory(folder).create(recursive: true);
    await replaceFile(p.join(folder, 'tree.json'), utf8.encode(tree));
    log.i('kept the v$treeWireVersion tree of ${chapter.path} in $folder');
  }

  /// What the engine was last started with, so a settings change that
  /// touches neither its threads nor its table does not restart it.
  (int, int)? _engineRunsWith;

  /// The engine follows the settings: more lines at once, a new process for
  /// new threads or a new table.
  void _engineSettings() {
    final s = _settings.value;
    _analysis.setLines(s.engineLines);
    final wanted = (s.engineCores, s.engineMemoryMb);
    if (_engineRunsWith != wanted) {
      _engineRunsWith = wanted;
      unawaited(_analysis.restart());
    }
  }

  List<SettingGroup> _settingRows() => settingGroups(
    store: _settings,
    coresAvailable: Platform.numberOfProcessors,
    account: _account,
    openLogFolder: () => unawaited(openFolder(widget.logFolder)),
  );

  /// The dialog on the way out is raised over the app, not over this widget,
  /// which sits above the navigator that shows it.
  final _navigator = GlobalKey<NavigatorState>();
  late final _exit = ExitGuard(
    saver: _saver,
    question: DraftDialog(_navigator),
    saveCopy: _saveCopy,
  );

  /// Writes the words on screen beside the original, under a name the user
  /// gives, and answers the file it wrote. The question on the way out
  /// points at this because it is the one way out that keeps them.
  ///
  /// The copy does not take the session over: the user answered this while
  /// going somewhere else, and the document they are going to is the one
  /// they asked for.
  Future<String?> _saveCopy() async {
    final context = _navigator.currentContext;
    if (context == null) return null;
    final name = await showCopyNameDialog(
      context,
      _session.chapter?.name ?? 'Chapter',
    );
    if (name == null) return null;
    final written = await copyAside(_session, _saver, name);
    return written is CopySaved ? written.name : null;
  }

  late final _requests = WorkspaceRequests(
    session: _session,
    library: _library,
    studies: _studies,
    viewer: _viewer,
    games: _games,
    leaving: _exit,
    input: DialogInput(_navigator),
  );

  /// The old app's tactics set, one game per puzzle, read and written in
  /// place so both apps keep one record of every attempt.
  late final _tactics = TacticsSet(
    documents: _store,
    session: _session,
    settings: _settings,
    ref: ChapterRef.at(
      p.join(widget.documents.path, 'tactics_sets', 'Default.pgn'),
    ),
  );
  late final _trainer = PuzzleTrainer(
    set: _tactics,
    session: _session,
    analysis: _analysis,
    settings: _settings,
    open: (set, game) async =>
        await _requests.open(set, game: game) is RequestDone,
  );

  /// The user's downloaded games, one file per account, shared with the old
  /// app.
  late final _gamesCache = GamesCache(
    _store,
    folder: p.join(widget.documents.path, 'games_library'),
  );

  /// The user's games read against their repertoires, for My games.
  late final _gameBook = GameBook(
    accounts: PreferencesAccounts(),
    cache: _gamesCache,
    shelf: _shelf,
  );

  /// The accounts as the book last heard of them: a download or a new
  /// username gives the review a new map, which is when the book reads
  /// the games again.
  Map<GameSite, Account>? _accountsSeen;

  void _gamesMayHaveChanged() {
    final accounts = _myGames.accounts;
    if (identical(accounts, _accountsSeen)) return;
    _accountsSeen = accounts;
    _gameBook.recheck();
  }

  /// The user's accounts and the review that mines their games into the
  /// set, on a Stockfish of its own with the pane's threads and table.
  late final _myGames = MyGames(
    accounts: PreferencesAccounts(),
    sites: [
      LichessGamesApi(_lichess, token: readLichessToken),
      ChesscomGamesApi(_lichess),
    ],
    cache: _gamesCache,
    set: SetAdditions(
      documents: _store,
      session: _session,
      saver: _saver,
      set: _tactics,
      older: () => readOlderAnalyzed(widget.documents),
    ),
    engine: () => launchStockfish(
      support: widget.support,
      engines: _engines,
      cores: _settings.value.engineCores,
      memoryMb: _settings.value.engineMemoryMb,
    ),
  );

  late final _quit = AppExit(
    guard: _exit,
    stopEngines: _engines.dispose,
    closeLog: widget.closeLog,
  );

  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: _quit.leave,
      // Leaving the window is the moment a draft stops waiting for its
      // clock: whatever the user switches to might be the old app, opening
      // the same file.
      onInactive: _flushDraft,
      onHide: _flushDraft,
    );
    // A library change is a chapter file written, so what the other
    // chapters answer is read again the next time a chapter is walked.
    _library.addListener(_answers.forget);
    _library.addListener(_tree.forget);
    _library.addListener(_gameBook.recheck);
    _myGames.addListener(_gamesMayHaveChanged);
    _fill.addListener(_listTheDraft);
    unawaited(_library.refresh());
    unawaited(_startWithSettings());
    unawaited(_myGames.load());
  }

  /// The settings are read before the engine starts, so its first process
  /// already has the threads and the table the user chose.
  Future<void> _startWithSettings() async {
    await _settings.load();
    unawaited(_account.load());
    final s = _settings.value;
    _engineRunsWith = (s.engineCores, s.engineMemoryMb);
    _analysis.setLines(s.engineLines);
    _settings.addListener(_engineSettings);
    await _analysis.enable();
  }

  void _flushDraft() => unawaited(_saver.flush());

  /// A finished fill wrote a chapter the library has not listed; reading
  /// the folders again is what puts the draft in the outline. The fill
  /// notifies only when its own state changes, not with the document.
  void _listTheDraft() {
    if (_fill.state is FillDone) unawaited(_library.refresh());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _settings.removeListener(_engineSettings);
    _account.dispose();
    _requests.dispose();
    _lineTrainer.dispose();
    _myGames.removeListener(_gamesMayHaveChanged);
    _myGames.dispose();
    _gameBook.dispose();
    _tactics.dispose();
    _fill.removeListener(_listTheDraft);
    _fill.dispose();
    _trainer.dispose();
    _evalCache.close();
    _analysis.dispose();
    _replies.dispose();
    _gaps.dispose();
    _explorer.dispose();
    _tree.dispose();
    _games.dispose();
    _book.close();
    _maia.dispose();
    _settings.dispose();
    _outline.dispose();
    _library.removeListener(_answers.forget);
    _library.removeListener(_tree.forget);
    _library.removeListener(_gameBook.recheck);
    _library.dispose();
    _studies.dispose();
    _viewer.dispose();
    _lichess.close();
    _session.dispose();
    _saver.dispose();
    unawaited(_engines.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chess Auto Prep',
      navigatorKey: _navigator,
      theme: darkTheme(),
      debugShowCheckedModeBanner: false,
      home: Shell(
        myGames: _myGames,
        book: _gameBook,
        requests: _requests,
        library: _library,
        studies: _studies,
        viewer: _viewer,
        settings: _settings,
        settingRows: _settingRows,
        settingsAlso: _account,
        outline: _outline,
        session: _session,
        saver: _saver,
        analysis: _analysis,
        replies: _replies,
        gaps: _gaps,
        explorer: _explorer,
        tree: _tree,
        games: _games,
        fill: _fill,
        tactics: _tactics,
        trainer: _trainer,
        lineTrainer: _lineTrainer,
      ),
    );
  }
}
