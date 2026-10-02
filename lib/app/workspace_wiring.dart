import 'dart:async';
import 'dart:io' show Platform;

import '../chess/generation/evaluation_source.dart';

import '../engines/engine_supervisor.dart';
import '../net/chessdb_moves.dart';
import '../net/search_evaluator.dart';
import '../engines/fixed_depth.dart';
import '../workspace/repertoire_catalog.dart';
import '../storage/eval_cache.dart' show CachedEvaluator;
import '../storage/my_games_files.dart';
import '../workspace/board_book.dart';
import '../workspace/books.dart';
import '../workspace/chapter_audit.dart';
import '../workspace/collection_analysis.dart';
import '../workspace/engine_analysis.dart';
import '../workspace/engine_jobs.dart';
import '../workspace/explorer.dart';
import '../workspace/file_filter.dart';
import '../workspace/fill_gaps.dart';
import '../workspace/fill_states.dart';
import '../workspace/finds.dart';
import '../workspace/game_fetcher.dart';
import '../workspace/gap_hunt.dart';
import '../workspace/local_games.dart';
import '../workspace/opening_names.dart';
import '../workspace/replies.dart';
import '../workspace/repertoire_shelf.dart';
import '../workspace/repertoire_tree.dart';
import '../workspace/search_opponents.dart';
import '../workspace/workspace.dart';
import '../workspace/game_review.dart';
import '../workspace/solitaire.dart';
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
    _env.store.addListener(_corpusChanged);
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
    jobs: _jobs,
    session: _session,
    inspection: _inspection,
    review: _review,
    solitaire: _solitaire,
    audit: _audit,
    boardBook: _boardBook,
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
    openings: _openings,
    coresAvailable: Platform.numberOfProcessors,
  );

  late final _openings = OpeningNames(_env.openingBook);

  late final _analysis = EngineAnalysis(
    _session,
    _env.startEngine,
    multiPv: _env.settings.value.engineLines,
    elsewhere: _tree.board,
  );

  late final _review = GameReview(
    session: _session,
    jobs: _jobs,
    launch: _env.startEngine,
  );

  late final _solitaire = Solitaire(_session, _analysis);

  late final _boardBook = BoardBook(
    session: _session,
    shelf: _shelf,
    books: _books,
  );

  late final _inspection = CollectionAnalysis(
    source: _session,
    store: _env.store,
    launch: _env.startEngine,
    sourceEngine: _analysis,
    multiPv: _env.settings.value.engineLines,
  );

  late final _fileTree = FileTree(filter: _filter);
  late final _myGamesTree = MyGamesTree(
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

  /// The one heavy engine job at a time: a search, its lines, an audit, a
  /// game review, a tournament.
  late final _jobs = EngineJobs(_analysis, analysisTab: _inspection.engine);

  /// For owners outside the workspace whose engines are one of the jobs.
  EngineJobs get jobs => _jobs;

  late final _audit = ChapterAudit(
    session: _session,
    jobs: _jobs,
    launch: _env.startEngine,
    evalCache: _env.evalCache,
    store: _env.audits,
    model: _replyModel,
    settings: _env.settings,
    answers: _answers,
    lookups: _env.lookups,
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
    jobs: _jobs,
    documents: _env.store,
    tools: _fillTools,
    keepTree: _env.keepTree,
    loadTree: _env.loadTree,
    pendingWrites: _env.pendingWrites,
    finds: _finds,
    openings: _openings,
    clock: _env.now,
  );

  late final _finds = Finds(
    store: _env.finds,
    clock: _env.now,
    pendingWrites: _env.pendingWrites,
  );

  /// A second Stockfish for the fill, with the pane's threads and table:
  /// the pane's own engine is paused for the run, so the machine is not
  /// shared, and quitting this one when the run ends costs nothing the pane
  /// has to rebuild.
  Future<FillToolsResult> _fillTools(FillRequest request) async {
    if (request.method == SearchMethod.mainline) return _bookTools();
    final started = await _env.startEngine();
    if (started is StartFailed) return FillUnavailable(started.reason);
    final engine = (started as Started).engine;
    final local = CachedEvaluator(
      FixedDepthEvaluator(engine, depth: request.evalDepth),
      _env.evalCache(),
      depth: request.evalDepth,
    );
    final remote = request.source == EvaluationSource.stockfish
        ? null
        : SearchEvaluator(
            source: request.source,
            fallback: local,
            minDepth: request.evalDepth,
            run: _env.lookups.run(),
          );
    return FillReady(
      evaluator: remote ?? local,
      candidates: FixedDepthCandidates(engine, depth: request.evalDepth),
      policy: opponentFor(
        request,
        maia: _env.maia,
        explorer: _env.lichessExplorer,
        book: _env.masterBook,
      ),
      continuations: FixedDepthEvaluator(engine, depth: request.evalDepth),
      release: () async {
        remote?.close();
        await engine.quit();
      },
    );
  }

  /// ChessDB through the environment's one client, a run of its own, and
  /// the master games on this machine for the opponent's replies.
  FillToolsResult _bookTools() => BookReady(
    chessDb: ChessDbMoves(_env.lookups.run()),
    practiceAt: MastersPlayed(_env.masterBook).at,
  );

  /// Applies engine settings without launching analysis. Each app session
  /// starts off; the workspace switch or E enables it on demand.
  Future<void> start() async {
    if (_disposed) return;
    final s = _env.settings.value;
    _engineRunsWith = (s.engineCores, s.engineMemoryMb);
    _analysis
      ..setLines(s.engineLines)
      ..showThreat(s.engineThreat);
    _inspection.engine.setLines(s.engineLines);
    _env.settings.addListener(_engineSettings);
  }

  /// What the engine was last started with, so a settings change that
  /// touches neither its threads nor its table does not restart it.
  (int, int)? _engineRunsWith;

  /// More lines at once, or a new process for new threads or a new table.
  void _engineSettings() {
    final s = _env.settings.value;
    _analysis
      ..setLines(s.engineLines)
      ..showThreat(s.engineThreat);
    _inspection.engine.setLines(s.engineLines);
    final wanted = (s.engineCores, s.engineMemoryMb);
    if (_engineRunsWith != wanted) {
      _engineRunsWith = wanted;
      unawaited(_analysis.restart());
      unawaited(_inspection.engine.restart());
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
    } else if (change.folder) {
      _answers.forget();
    } else {
      // Another repertoire's chapter: read again when a chapter beside it
      // is next walked.
      _answers.forgetFile(change.path);
      if (change.movedTo case final to?) _answers.forgetFile(to);
    }
    final inputs = _books.inputs(_books.active);
    if (all || inputs.any(change.touches)) {
      _tree.forget();
    } else {
      // The shelf holds every book, not only the one in use: a book taken
      // up next, or a game checked against it, reads the change.
      _shelf.forget();
    }
  }

  /// Download timestamps are not the source: revoke the corpus at its actual
  /// committed PGN boundary, including creations and folder relocations.
  void _corpusChanged() {
    final change = _env.store.lastChange;
    if (change != null && change.touches(_gamesCache.folder)) {
      _myGamesTree.forget();
    }
  }

  void dispose() {
    _disposed = true;
    _env.store.removeListener(_corpusChanged);
    _env.settings.removeListener(_engineSettings);
    _catalog.removeListener(_filesChanged);
    _fill.dispose();
    _audit.dispose();
    _jobs.dispose();
    _openings.dispose();
    _finds.dispose();
    _review.dispose();
    _solitaire.dispose();
    _boardBook.dispose();
    _inspection.dispose();
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
