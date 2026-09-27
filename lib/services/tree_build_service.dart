/// Owns the persistent tree build lifecycle, cancellation and pause gate.
///
/// Stockfish expectimax delegates to PureTreeBuilder: exhaustive fixed-horizon
/// search by default, or explicit approximate rolling four-ply lookahead. Both
/// enumerate every legal own candidate before the engine-loss constraint and
/// preserve the complete positive-support Maia opponent policy. No game
/// database contributes probabilities to Stockfish expectimax.
///
/// The legacy frontier/expansion collaborators below still serve database
/// exploration modes. Their heuristics do not run in Stockfish expectimax.
/// ExpectimaxCalculator and RepertoireSelector back up and export the declared
/// policy afterward; Rolling's saved commitments remain fixed during backup.
library;

import 'dart:async';
import 'dart:convert';

import '../chess_core/generation/build_tree_node.dart';
import '../utils/fen_utils.dart';
import 'engine/engine_interrupt.dart';
import 'engine/engine_lifecycle.dart';
import 'engine/stockfish_pool.dart';
import 'coverage_sweep.dart';
import 'eval/chessdb_api_provider.dart';
import 'generation/build_run.dart';
import 'generation/fen_map.dart';
import 'generation/frontier_queue.dart';
import 'generation/generation_config.dart';
import 'generation/lanes.dart';
import 'generation/node_expander.dart';
import 'generation/pgn_freq_map.dart';
import 'generation/pure_tree_builder.dart';
import 'generation/run_debug_dump.dart';
import 'generation/tree_build_progress.dart';
import 'generation/tree_eval_resolver.dart';
import 'generation/tree_prune.dart';
import 'jobs/generation_phase.dart';
import 'master_games/master_games_db.dart' show BookLookup;
import 'tree_build_db_explorer.dart';
import 'tree_build_gates.dart';
import 'tree_build_types.dart';

export 'tree_build_types.dart' show BuildCancelledException;

class TreeBuildService {
  TreeBuildService({
    required StockfishPool pool,
    required EngineLifecycle lifecycle,
  }) : _pool = pool,
       _lifecycle = lifecycle;
  final StockfishPool _pool;
  final EngineLifecycle _lifecycle;
  final TreeEvalResolver _evalResolver = TreeEvalResolver();

  static const int _frontierMinPlySentinel = 1 << 30;

  bool _isBuilding = false;
  bool _isPaused = false;
  Completer<void>? _pauseCompleter;

  /// State of the current (or most recent) run.  Kept after completion so
  /// [buildElapsedMs] and friends stay readable.
  BuildRun? _run;

  BuildStats _stats = BuildStats();

  /// Full log of the most recent run, kept for the end-of-run debug dump.
  final RunDebugLog runLog = RunDebugLog();

  /// Eval-too-low lines removed by the post-build prune of the most recent
  /// [build] run (they no longer exist in the returned tree).
  List<PrunedLine> lastPrunedTooLow = const [];

  /// Leaves the coverage sweep removed for being under the coverage floor
  /// with no reply of ours — recorded for the same reason as
  /// [lastPrunedTooLow]: "was this line ever generated?" is otherwise
  /// unanswerable, because the sweep deletes silently.
  List<PrunedLine> lastRemovedUncovered = const [];

  /// Human-practice statistics scanned from the user's PGN database by the
  /// most recent DB Explorer run, or null when the last build had no game
  /// database behind it.  Downstream phases (model-game selection, practical
  /// scores) read it; it is cleared at the start of every run so a later
  /// engine-only build cannot inherit a previous run's games.
  PgnFreqMap? lastGameDatabase;

  BuildStats get buildStats => _stats;
  ChessDbApiProvider? get chessDbApiProvider =>
      _evalResolver.chessDbApiProvider;

  /// True while Phase 1 BFS is running ([build] in progress).
  bool get isBuilding => _isBuilding;

  /// Phase 1 active-build elapsed time; stops advancing while [pauseBuild] holds.
  int get buildElapsedMs => _run?.stopwatch.elapsedMilliseconds ?? 0;

  BuildTree? _currentTree;
  BuildTree? get currentTree => _currentTree;

  /// Incremental position index of the active build; display lookup only.
  BuildTreeNode? liveNodeAt(String fen) => _run?.fenMap.getCanonical(fen);

  bool get isPaused => _isPaused;

  /// Pause is honored at every async loop in the build (BFS, eval
  /// enrichment, coverage sweep) via [waitIfPaused] — not only Phase 1.
  void pauseBuild() {
    if (_isPaused) return;
    _isPaused = true;
    _pauseCompleter = Completer<void>();
    final sw = _run?.stopwatch;
    if (_isBuilding && sw != null && sw.isRunning) sw.stop();
  }

  void resumeBuild() {
    if (!_isPaused) return;
    _isPaused = false;
    if (_isBuilding) _run?.stopwatch.start();
    _pauseCompleter?.complete();
    _pauseCompleter = null;
  }

  /// Blocks while the build is paused.  Loops that can yield safely call
  /// this at the top of each iteration so pause takes effect promptly.
  Future<void> waitIfPaused() async {
    while (_isPaused && _pauseCompleter != null) {
      await _pauseCompleter!.future;
    }
  }

  /// Request a hard stop of the running build.  The tree stays resumable;
  /// downstream phases are skipped.  Also releases a pause so the build can
  /// unwind promptly.
  void stopBuild() {
    _run?.cancel.requestStop();
    _pool.stopAll();
    if (_isPaused) {
      _isPaused = false;
      _pauseCompleter?.complete();
      _pauseCompleter = null;
    }
  }

  void _log(String msg) {
    runLog.add('[TreeBuild] $msg');
  }

  /// Set up per-run state.  MUST be called synchronously from the public
  /// entry points, before their first `await`, so overlapping calls hit the
  /// re-entrancy guard instead of racing each other's state.
  BuildRun _startRun({
    required TreeBuildConfig config,
    required BuildTree tree,
    required FenMap fenMap,
    required bool Function() isCancelled,
    required bool Function() finishNow,
    required void Function(BuildProgress) onProgress,
    required int nextNodeId,
    BookLookup? masterBook,
  }) {
    if (_isBuilding) {
      throw StateError('A tree build is already running');
    }
    _isBuilding = true;
    _isPaused = false;
    _pauseCompleter = null;
    _stats = BuildStats();
    _evalResolver.stats = _stats;
    runLog.clear();
    lastPrunedTooLow = const [];
    lastRemovedUncovered = const [];
    lastGameDatabase = null;

    final run = BuildRun(
      config: config,
      tree: tree,
      fenMap: fenMap,
      pool: _pool,
      evalResolver: _evalResolver,
      stats: _stats,
      runLog: runLog,
      progress: TreeBuildProgressTracker(),
      onProgress: onProgress,
      cancel: BuildCancellation(isCancelledExternally: isCancelled),
      finishNow: finishNow,
      waitIfPaused: waitIfPaused,
      nextNodeId: nextNodeId,
      masterBook: masterBook,
    );
    run.stopwatch.start();
    run.progress.reset(
      buildStartTotalNodes: 0,
      bestFirst: config.bestFirst,
      minProbability: config.minProbability,
    );
    _run = run;
    _currentTree = tree;
    return run;
  }

  /// A fresh tree holding only [config]'s start position, and the id the
  /// next node takes.
  static (BuildTree, int nextNodeId) _newTree(TreeBuildConfig config) {
    final rootFen = config.startFen;
    final root = BuildTreeNode(
      fen: rootFen,
      moveSan: '',
      moveUci: '',
      ply: 0,
      isWhiteToMove: isWhiteToMove(rootFen),
      nodeId: 1,
    );
    final tree = BuildTree(root: root, configSnapshot: config.toJson());
    tree.registerNode(root);
    return (tree, 2);
  }

  // ── Public API ─────────────────────────────────────────────────────────

  /// Phase 1 build.  [isCancelled] is the hard-cancel signal (the tree stays
  /// resumable, downstream phases are skipped).  [finishNow] stops BFS
  /// expansion but still runs the coverage sweep and post-build prune, so the
  /// caller can proceed to selection on a hole-free partial tree.
  Future<BuildTree> build({
    required TreeBuildConfig config,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
    bool Function()? finishNow,
    BuildTree? existingTree,
    BookLookup? masterBook,
  }) async {
    // Everything up to the try block is synchronous: the re-entrancy guard
    // in _startRun and the run state must be in place before the first
    // await, or two overlapping build() calls both pass the guard.
    BuildTree tree;
    int nextNodeId;
    if (existingTree != null) {
      tree = existingTree;
      nextNodeId = findMaxNodeId(tree.root) + 1;
      if (tree.nodeIndex.isEmpty) {
        tree.computeMetadata();
      }
    } else {
      (tree, nextNodeId) = _newTree(config);
    }

    final run = _startRun(
      config: config,
      tree: tree,
      fenMap: FenMap(),
      isCancelled: isCancelled,
      finishNow: finishNow ?? () => false,
      onProgress: onProgress,
      nextNodeId: nextNodeId,
      masterBook: masterBook,
    );
    _log(
      'Build start: resume=${existingTree != null}, '
      'config=${jsonEncode(config.toJson())}',
    );

    try {
      await Future.wait([
        if (config.usesStockfish && _lifecycle.state != EngineState.generating)
          _pool.prepareForTreeBuild(config.resolvedEngineThreads)
        else
          Future.value(),
        if (config.buildMode != BuildMode.stockfishExpectimax)
          _evalResolver.evalCache.init(),
      ]);
      if (config.buildMode != BuildMode.stockfishExpectimax) {
        await _evalResolver.initProviders(config);
      }
      if (config.usesStockfish && _pool.workerCount == 0) {
        throw StateError('No engine workers available');
      }

      if (config.relativeEval &&
          config.buildMode != BuildMode.stockfishExpectimax) {
        final rootFenMap = FenMap();
        final gotEval = await _evalResolver.ensureEval(
          tree.root,
          config,
          fenMap: rootFenMap,
          pool: _pool,
          dbOnly: !config.usesStockfish,
        );
        if (!gotEval && !config.usesStockfish) {
          throw StateError(
            'Root position has no database eval — enable an eval source '
            '(local ChessDB, cdbdirect, or ChessDB API)',
          );
        }
        run.config = config.anchoredToRoot(tree.root);
      }

      run.progress.reset(
        buildStartTotalNodes: tree.totalNodes,
        bestFirst: run.config.bestFirst,
        minProbability: run.config.minProbability,
      );

      if (config.buildMode == BuildMode.stockfishExpectimax) {
        try {
          await PureTreeBuilder(run).build();
          tree.computeMetadata();
          lastPrunedTooLow = [];
          return tree;
        } finally {
          await _evalResolver.teardownProviders();
        }
      }
      final expander = NodeExpander.forRun(run);

      try {
        await _buildBfsLoop(run, expander);
        // Skipped on hard cancel: the tree stays resumable and the sweep
        // would only throw away resumable frontier leaves.  Finish-now DOES
        // sweep — the caller proceeds to selection, so the partial tree
        // must carry the no-silent-holes guarantee.
        if (!run.isCancelled) {
          await _coverageSweep(run, expander);
        }
      } finally {
        run.fenMap.clear();
        await _evalResolver.teardownProviders();
      }

      final prunedLines = <PrunedLine>[];
      final pruned = pruneEvalTooLow(
        tree,
        playAsWhite: config.playAsWhite,
        removedLines: prunedLines,
      );
      lastPrunedTooLow = prunedLines;
      if (pruned > 0) {
        _log(
          'Pruned $pruned eval-too-low nodes '
          '(${prunedLines.length} subtree roots)',
        );
      }

      // Complete = frontier exhausted (neither cancelled nor finished early).
      tree.buildComplete = !run.isCancelled && !run.shouldFinish();

      _log(
        'Build complete: ${tree.totalNodes} nodes, '
        'ply ${tree.maxPlyReached}, '
        '${run.stopwatch.elapsedMilliseconds}ms',
      );
      _log('Stats: ${jsonEncode(_stats.toJson())}');

      return tree;
    } on Object catch (e) {
      if (run.isCancelled && isEngineInterrupt(e)) {
        tree.buildComplete = false;
        return tree;
      }
      rethrow;
    } finally {
      _isBuilding = false;
      run.stopwatch.stop();
    }
  }

  /// Build a tree by parsing PGN files into a frequency map, then BFS-
  /// expanding from the root using move frequencies.  Matches C
  /// `tree_build_from_freqmap` + `tree_enrich_evals`; the phases live in
  /// [DbExplorerTreeBuilder].
  ///
  /// [finishNow] stops the BFS expansion early but does NOT skip eval
  /// enrichment or the coverage sweep — a finished-early tree still gets
  /// evals so downstream selection has something to work with.  Throws
  /// [BuildCancelledException] when hard-cancelled during PGN parsing.
  Future<BuildTree> buildFromPgnFreqMap({
    required TreeBuildConfig config,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
    bool Function()? finishNow,
    void Function(String status, GenerationPhase phase)? onStatusChanged,
    String? startMoves,
  }) async {
    if (config.pgnFilePaths.isEmpty) {
      throw StateError('DB Explorer requires at least one PGN file.');
    }

    // Synchronous prologue — see _startRun for why.
    final (tree, nextNodeId) = _newTree(config);
    tree.root.cumulativeProbability = 1.0;
    tree.root.searchPriority = 1.0;

    final run = _startRun(
      config: config,
      tree: tree,
      fenMap: FenMap(),
      isCancelled: isCancelled,
      finishNow: finishNow ?? () => false,
      onProgress: onProgress,
      nextNodeId: nextNodeId,
    );
    _log('DB Explorer start: config=${jsonEncode(config.toJson())}');
    final explorer = DbExplorerTreeBuilder(run);

    try {
      onStatusChanged?.call('Parsing PGN files...', GenerationPhase.parsingPgn);
      final (freqMap, freqStats) = await explorer.parseGames(
        startMoves: startMoves,
      );
      lastGameDatabase = freqMap;

      onStatusChanged?.call(
        'Building tree from ${freqStats.totalGames} games, '
        '${freqStats.positions} positions...',
        GenerationPhase.buildingTree,
      );
      await explorer.expand(freqMap);

      // Eval enrichment runs on finish-now too — a tree without evals is
      // useless to the selection phases downstream.
      if (!run.isCancelled) {
        onStatusChanged?.call(
          'Enriching evals (${tree.totalNodes} nodes)...',
          GenerationPhase.enrichingEvals,
        );

        await _evalResolver.evalCache.init();
        await _evalResolver.initProviders(config);

        if ((config.usesStockfish || config.needsStockfish) &&
            _lifecycle.state != EngineState.generating) {
          await _pool.prepareForTreeBuild(config.resolvedEngineThreads);
        }

        try {
          await explorer.enrichEvals();
          // After enrichment the engine is available, so holes where the
          // user's games ran out can get an engine answer.
          if (!run.isCancelled) {
            await _coverageSweep(run, NodeExpander.forRun(run));
          }
        } finally {
          run.fenMap.clear();
          await _evalResolver.teardownProviders();
        }
      }

      _log(
        'DB Explorer complete: ${tree.totalNodes} nodes, '
        '${run.stopwatch.elapsedMilliseconds}ms',
      );
      _log('Stats: ${jsonEncode(_stats.toJson())}');

      return tree;
    } on Object catch (e) {
      if (run.isCancelled && isEngineInterrupt(e)) {
        tree.buildComplete = false;
        return tree;
      }
      rethrow;
    } finally {
      _isBuilding = false;
      run.stopwatch.stop();
    }
  }

  // ── BFS build loop ─────────────────────────────────────────────────────

  /// Collect frontier leaves for resume — matches C `resume_prepare_frontier`.
  ///
  /// A node still awaiting expansion is a frontier leaf whether or not it
  /// already has children (a partial expansion); nothing below it is walked.
  static (List<BuildTreeNode> frontier, int minPly) prepareResumeFrontier(
    BuildTreeNode root,
  ) {
    final frontier = <BuildTreeNode>[];
    var minPly = _frontierMinPlySentinel;
    void walk(BuildTreeNode node) {
      if (!node.explored) {
        frontier.add(node);
        if (node.ply < minPly) minPly = node.ply;
        return;
      }
      for (final child in node.children) {
        walk(child);
      }
    }

    walk(root);
    if (frontier.isEmpty) minPly = 0;
    return (frontier, minPly);
  }

  /// Shallowest ply among nodes that still need expansion (for progress UI).
  static int? minFrontierPly(BuildTreeNode root) {
    final (_, minPly) = prepareResumeFrontier(root);
    return minPly > 0 && minPly < _frontierMinPlySentinel ? minPly : null;
  }

  Future<void> _buildBfsLoop(BuildRun run, NodeExpander expander) async {
    final tree = run.tree;
    final config = run.config;
    final queue = FrontierQueue(bestFirst: config.bestFirst);

    final fastResume = tree.totalNodes > 1 && tree.root.children.isNotEmpty;
    if (fastResume) {
      final (frontier, minPly) = prepareResumeFrontier(tree.root);
      if (frontier.isEmpty) {
        _log('No frontier positions to expand');
        return;
      }
      // The transposition table is per run, and only nodes that pass through
      // the queue register in it — which on resume is the frontier alone.
      // Without seeding it from the saved tree, a frontier leaf whose
      // position was already expanded last session is expanded again: the
      // same engine work twice and a second copy of the subtree that nothing
      // links to the first.  (The eval chain also reads the canonical node to
      // reuse its eval.)
      run.fenMap.registerExpanded(tree.root);
      // Legacy trees carry no priorities; reach probability is the natural
      // fallback (equals the priority when no alt-discount applied).
      for (final n in frontier) {
        if (n.searchPriority < 0.0) {
          n.searchPriority = n.cumulativeProbability;
        }
      }
      if (!config.bestFirst) {
        frontier.sort((a, b) => a.ply.compareTo(b.ply));
      }
      queue.addAll(frontier);
      run.progress.initForResume(minFrontierPly: minPly);
    } else {
      tree.root.searchPriority = 1.0;
      queue.add(tree.root);
    }

    // Nodes some lane is expanding right now.  A transposition resolved by
    // another lane can re-queue a node whose reach just crossed the floor
    // ([addArrivalCumP]); if that node is mid-expansion the re-queue is
    // dropped — its children are enqueued by the expansion in progress.
    final inFlight = <int>{};
    final gate = LaneGate();

    Future<void> lane() async {
      while (!run.isCancelled && !run.shouldFinish()) {
        await waitIfPaused();
        if (run.isCancelled) return;
        if (queue.isEmpty) {
          if (inFlight.isEmpty) return;
          // Another lane may still enqueue children; wait for it to finish
          // a node rather than declaring the frontier exhausted.
          await gate.changed;
          continue;
        }
        final node = queue.removeFirst();
        if (!inFlight.add(node.nodeId)) continue;
        run.progress.onDequeue(
          node.ply,
          priority: effectiveSearchPriority(node),
          frontierSize: queue.length,
        );
        try {
          await _processBuildNode(
            run: run,
            node: node,
            queue: queue,
            expander: expander,
          );
        } finally {
          inFlight.remove(node.nodeId);
          gate.signal();
        }
      }
    }

    await Future.wait([for (var i = 0; i < run.expansionLanes; i++) lane()]);
  }

  Future<void> _processBuildNode({
    required BuildRun run,
    required BuildTreeNode node,
    required FrontierQueue queue,
    required NodeExpander expander,
  }) async {
    if (run.isCancelled) return;

    // Pause gate: if paused, wait until resumed or cancelled
    await waitIfPaused();
    if (run.isCancelled) return;

    final config = run.config;
    final tree = run.tree;
    final isOurMove = node.isWhiteToMove == config.playAsWhite;

    // Coverage floor: an our-turn node owes the opponent's last move an
    // answer whenever that move's LOCAL probability clears coverMinProb —
    // even below the search floor, past maxPly, or past the node budget.
    // Such nodes get a coverage-only expansion: evaluated answer, no subtree.
    final owesAnswer =
        isOurMove &&
        node.ply > 0 &&
        node.children.isEmpty &&
        config.coverMinProb > 0.0 &&
        node.moveProbability >= config.coverMinProb;
    var coverageOnly = false;

    // Depth cap: maxPly, or further while the position is master practice
    // (see BuildRun.plyCapAt) — book lines run deeper, Maia-only ones do not.
    if (node.ply >= run.plyCapAt(node.fen, node.ply)) {
      if (!owesAnswer) {
        if (!node.hasEngineEval && config.usesStockfish) {
          await _evalResolver.ensureEval(
            node,
            config,
            fenMap: run.fenMap,
            pool: _pool,
          );
        }
        run.markExplored(node);
        return;
      }
      coverageOnly = true;
    }
    if (run.belowSearchFloor(node) && !coverageOnly) {
      if (!owesAnswer) return;
      coverageOnly = true;
    }
    if (config.maxNodes > 0 && tree.totalNodes >= config.maxNodes) {
      if (!owesAnswer) return;
      coverageOnly = true;
    }

    run.emitNodeProgress(node);

    // Resume: fully expanded in a prior session — enqueue children only.
    if (node.children.isNotEmpty && node.explored) {
      run.fenMap.putCanonical(node.fen, node);
      for (final child in node.children) {
        if (run.isCancelled) break;
        queue.add(child);
      }
      return;
    }
    if (node.explored) return;

    // Opponent-move nodes: ensure eval + window prune BEFORE expansion.
    // Our-move nodes skip this wherever the expander resolves the eval itself
    // (Stockfish MultiPV, the ChessDB book) — see
    // [TreeBuildConfig.expanderSuppliesOurMoveEval]. In maiaDbExplore mode,
    // both sides need a DB eval before expanding.
    if (!isOurMove || !config.expanderSuppliesOurMoveEval) {
      final gotEval = await _evalResolver.ensureEval(
        node,
        config,
        fenMap: run.fenMap,
        pool: _pool,
        dbOnly: !config.usesStockfish,
      );
      if (!gotEval && !config.usesStockfish) {
        run.markExplored(node);
        return;
      }
      if (evalWindowPrune(node, config)) {
        run.markExplored(node);
        return;
      }
    }

    if (run.resolveTranspositionOrRegister(node, queue)) return;

    if (isOurMove) {
      await expander.expandOurMove(node, queue, coverageOnly: coverageOnly);
    } else {
      await expander.expandOpponentMove(node, queue);
    }

    // Mark explored only after expansion finishes so pause/cancel mid-call
    // leaves the node resumable (explored=false, possibly partial children).
    //
    // An expansion that produced neither a move nor a prune reason did not
    // actually happen — the usual cause is the engine returning no lines
    // because the pool was winding down at the end of a budgeted run. Calling
    // that "explored" freezes the gap permanently: the node is our turn, has
    // no move, and carries nothing to say why. Leaving it unexplored is both
    // honest and useful, since [prepareResumeFrontier] collects exactly these
    // and a resume retries them.
    //
    // A genuinely terminal position (mate or stalemate) also lands here and
    // stays unexplored forever. That is harmless — nothing re-queues it
    // during a run — and the engine's silence cannot be told apart from an
    // engine that is not answering, so claiming the node is finished would be
    // guessing.
    if (!run.isCancelled &&
        (node.children.isNotEmpty || node.pruneReason != PruneReason.none)) {
      run.markExplored(node);
    }
  }

  /// The coverage sweep (see [CoverageSweep]), recording what it removed in
  /// [lastRemovedUncovered].
  Future<void> _coverageSweep(BuildRun run, NodeExpander expander) async {
    final result = await CoverageSweep(run, expander).sweep();
    lastRemovedUncovered = result.removedLines;
  }
}
