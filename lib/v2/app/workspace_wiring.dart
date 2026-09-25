import 'dart:async';

import '../engines/engine_supervisor.dart';
import '../engines/fixed_depth.dart';
import '../workspace/repertoire_catalog.dart';
import '../storage/my_games_files.dart';
import '../workspace/books.dart';
import '../workspace/engine_analysis.dart';
import '../workspace/explorer.dart';
import '../workspace/file_filter.dart';
import '../workspace/fill_gaps.dart';
import '../workspace/finds.dart';
import '../workspace/game_fetcher.dart';
import '../workspace/gap_hunt.dart';
import '../workspace/local_games.dart';
import '../workspace/replies.dart';
import '../workspace/repertoire_shelf.dart';
import '../workspace/repertoire_tree.dart';
import '../workspace/workspace.dart';
import '../workspace/document_saver.dart';
import '../workspace/document_session.dart';
import 'environment.dart';

/// Builds the [Workspace] over the [AppEnvironment] and keeps its owners in step
/// with the rest of the app: the engine follows the settings, and a change
/// to the repertoire files makes what was read from them be read again.
final class WorkspaceWiring {
  WorkspaceWiring(
    this._env, {
    required DocumentSession session,
    required DocumentSaver saver,
    required RepertoireCatalog catalog,
    required FileFilter filter,
    required GamesCache games,
    required Books books,
  }) : _session = session,
       _books = books,
       _saver = saver,
       _catalog = catalog,
       _filter = filter,
       _gamesCache = games {
    _catalog.addListener(_filesChanged);
  }

  final AppEnvironment _env;
  final DocumentSession _session;
  final DocumentSaver _saver;
  final RepertoireCatalog _catalog;
  final FileFilter _filter;
  final GamesCache _gamesCache;
  final Books _books;
  bool _disposed = false;

  late final workspace = Workspace(
    session: _session,
    saver: _saver,
    settings: _env.settings,
    analysis: _analysis,
    explorer: _explorer,
    games: _games,
    replies: _replies,
    gaps: _gaps,
    shelf: _shelf,
    books: _books,
    tree: _tree,
    fill: _fill,
    finds: _finds,
    myGamesTree: _myGamesTree,
  );

  late final _analysis = EngineAnalysis(
    _session,
    _env.startEngine,
    multiPv: _env.settings.value.engineLines,
    elsewhere: _tree.board,
  );

  late final _fileTree = FileTree(filter: _filter);
  late final _myGamesTree = MyGamesTree(
    files: _env.chapterFiles,
    accounts: _env.accounts,
    cache: _gamesCache,
    store: _env.gameStore,
  );
  late final _databases = ExplorerDatabases(
    lichess: _env.lichessExplorer,
    book: _env.masterBook,
    thisFile: _fileTree,
    myGames: _myGamesTree,
  );
  late final _explorer = Explorer(
    session: _session,
    settings: _env.settings,
    databases: _databases,
    debounce: _env.explorerDelay,
  );
  late final _games = GameFetcher(
    databases: _databases,
    documents: _env.store,
    collections: _env.folders.collections,
  );

  late final _answers = RepertoireAnswers(
    files: _env.chapterFiles,
    documents: _env.store,
  );
  late final _replyModel = ReplyModel(
    policy: _env.maia,
    settings: _env.settings,
  );
  late final _gaps = GapHunt(
    session: _session,
    model: _replyModel,
    settings: _env.settings,
    answers: _answers,
  );
  late final _replies = Replies(
    session: _session,
    model: _replyModel,
    settings: _env.settings,
    gaps: _gaps,
  );

  late final _shelf = RepertoireShelf(
    files: _env.chapterFiles,
    documents: _env.store,
  );
  late final _tree = RepertoireTree(
    session: _session,
    shelf: _shelf,
    books: _books,
  );

  late final _fill = FillGaps(
    session: _session,
    analysis: _analysis,
    documents: _env.store,
    tools: _fillTools,
    keepTree: (chapter, tree) => _env.pendingWrites.track(
      chapter.path,
      _env.keepTree(chapter, tree),
      label: 'Search tree',
    ),
    finds: _finds,
    clock: _env.now,
  );

  late final _finds = Finds(store: _env.finds, clock: _env.now);

  /// A second Stockfish for the fill, with the pane's threads and table:
  /// the pane's own engine is paused for the run, so the machine is not
  /// shared, and quitting this one when the run ends costs nothing the pane
  /// has to rebuild.
  Future<FillToolsResult> _fillTools(FillRequest request) async {
    return switch (await _env.startEngine()) {
      StartFailed(:final reason) => FillUnavailable(reason),
      Started(:final engine) => FillReady(
        evaluator: CachedEvaluator(
          FixedDepthEvaluator(engine, depth: fillEvalDepth),
          _env.evalCache(),
          depth: fillEvalDepth,
        ),
        policy: MaiaOpponent(_env.maia, elo: request.elo),
        release: engine.quit,
      ),
    };
  }

  /// Starts the engine once the settings are read, and from then on has it
  /// follow them. Taken down first, it starts nothing.
  Future<void> start() async {
    if (_disposed) return;
    final s = _env.settings.value;
    _engineRunsWith = (s.engineCores, s.engineMemoryMb);
    _analysis.setLines(s.engineLines);
    _env.settings.addListener(_engineSettings);
    await _analysis.enable();
  }

  /// What the engine was last started with, so a settings change that
  /// touches neither its threads nor its table does not restart it.
  (int, int)? _engineRunsWith;

  /// More lines at once, or a new process for new threads or a new table.
  void _engineSettings() {
    final s = _env.settings.value;
    _analysis.setLines(s.engineLines);
    final wanted = (s.engineCores, s.engineMemoryMb);
    if (_engineRunsWith != wanted) {
      _engineRunsWith = wanted;
      unawaited(_analysis.restart());
    }
  }

  /// The repertoire files were listed anew: what the gaps and the explorer's Book
  /// read from them is read again.
  int _catalogInputs = -1;
  void _filesChanged() {
    if (_catalogInputs == _catalog.inputsRevision) return;
    _catalogInputs = _catalog.inputsRevision;
    final change = _catalog.admittedChange;
    final all = change == null;
    final source = _session.source;
    final repertoire = source == null
        ? null
        : _catalog.repertoireOf(source.path);
    if (all || (repertoire != null && change.touches(repertoire))) {
      _gaps.refreshAnswers();
    }
    final inputs = _books.inputs(_books.active);
    if (all || inputs.any(change.touches)) {
      _tree.forget();
    }
  }

  void dispose() {
    _disposed = true;
    _env.settings.removeListener(_engineSettings);
    _catalog.removeListener(_filesChanged);
    _fill.dispose();
    _finds.dispose();
    _analysis.dispose();
    _replies.dispose();
    _gaps.dispose();
    _explorer.dispose();
    _fileTree.dispose();
    _myGamesTree.dispose();
    _tree.dispose();
    _shelf.dispose();
    _games.dispose();
  }
}
