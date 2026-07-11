/// Two-phase tree builder — builds a persistent [BuildTree] with engine
/// evaluations on every node, matching the C tree_builder algorithm.
///
/// Phase 1 (this service): frontier-driven build with constant MultiPV at
/// our-move nodes, single-source opponent moves (Maia OR Lichess with an
/// optional Maia Dirichlet prior), eval-window pruning, and transposition
/// detection — matches C tree_builder.
///
/// Search algorithm (config.searchAlgorithm):
///   - Fast Expectimax (default): best-first frontier — pop the node with
///     the highest search priority (reach probability, discounted at
///     non-incumbent our-move alternatives) — plus priority-scaled pruning:
///     alternatives below the priority floor are skipped, MultiPV and the
///     eval-loss window shrink in cold subtrees, opponent fan-out is capped
///     harder, and our-move alternatives more than fastAltGapCp behind the
///     incumbent stay evaluated leaves instead of growing subtrees.
///     Anytime: at any node budget the tree concentrates on the
///     likeliest opponent lines, which also get searched deepest.  The
///     coverage floor is always honored (no silent holes).
///   - Pure Expectimax: classic level-order BFS, full configured search at
///     every node above the probability floor.
///
/// Structure: this service owns the run lifecycle (re-entrancy guard,
/// pause gate, cancellation) and the mode-independent build loop; how a
/// node grows children per [BuildMode] lives in `generation/node_expander`,
/// and per-run state (ids, stats, progress, cancellation token) in
/// `generation/build_run`.
///
/// Phase 2 (separate calculators): ease, expectimax, and repertoire
/// selection run on the completed tree.  Search priorities never feed
/// phase 2 — they shape which nodes exist, not how they are valued.
library;

import 'dart:async';
import 'dart:convert';

import '../models/build_tree_node.dart';
import '../utils/chess_utils.dart' show playUciMove, uciToSan;
import '../utils/fen_utils.dart';
import 'engine/stockfish_pool.dart';
import 'engine/engine_lifecycle.dart';
import 'eval/chessdb_api_provider.dart';
import 'generation/build_run.dart';
import 'generation/fen_map.dart';
import 'generation/frontier_queue.dart';
import 'generation/generation_config.dart';
import 'generation/node_expander.dart';
import 'generation/opponent_prior.dart';
import 'generation/pgn_freq_map.dart';
import 'generation/run_debug_dump.dart';
import 'generation/tree_build_progress.dart';
import 'jobs/generation_phase.dart';
import 'generation/tree_eval_resolver.dart';
import 'generation/tree_prune.dart';

/// Thrown when a build is cancelled before it can produce a usable tree
/// (e.g. during PGN parsing).  Callers treat this as a normal cancellation,
/// not a failure.
class BuildCancelledException implements Exception {
  final String message;
  const BuildCancelledException(this.message);

  @override
  String toString() => message;
}

class TreeBuildService {
  final StockfishPool _pool = StockfishPool.instance;
  final TreeEvalResolver _evalResolver = TreeEvalResolver();

  static const int _frontierMinPlySentinel = 1 << 30;
  static const int _externalEvalProgressInterval = 50;
  static const int _stockfishEvalProgressInterval = 10;

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

  BuildStats get buildStats => _stats;
  ChessDbApiProvider? get chessDbApiProvider =>
      _evalResolver.chessDbApiProvider;

  /// True while Phase 1 BFS is running ([build] in progress).
  bool get isBuilding => _isBuilding;

  /// Phase 1 active-build elapsed time; stops advancing while [pauseBuild] holds.
  int get buildElapsedMs => _run?.stopwatch.elapsedMilliseconds ?? 0;

  BuildTree? _currentTree;
  BuildTree? get currentTree => _currentTree;

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
      _evalResolver.reset();
      nextNodeId = 1;
      final rootFen = config.startFen;
      final root = BuildTreeNode(
        fen: rootFen,
        moveSan: '',
        moveUci: '',
        ply: 0,
        isWhiteToMove: isWhiteToMove(rootFen),
        nodeId: nextNodeId++,
      );
      tree = BuildTree(
        root: root,
        configSnapshot: config.toJson(),
      );
      tree.registerNode(root);
    }

    final run = _startRun(
      config: config,
      tree: tree,
      fenMap: FenMap(),
      isCancelled: isCancelled,
      finishNow: finishNow ?? () => false,
      onProgress: onProgress,
      nextNodeId: nextNodeId,
    );
    _log('Build start: resume=${existingTree != null}, '
        'config=${jsonEncode(config.toJson())}');

    try {
      await Future.wait([
        if (config.usesStockfish &&
            EngineLifecycle.instance.state != EngineState.generating)
          _pool.prepareForTreeBuild(config.resolvedEngineThreads)
        else
          Future.value(),
        _evalResolver.evalCache.init(),
      ]);
      await _evalResolver.initProviders(config);
      if (config.usesStockfish && _pool.workerCount == 0) {
        throw StateError('No engine workers available');
      }

      if (config.relativeEval) {
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
        if (tree.root.hasEngineEval) {
          final rootEvalUs = tree.root.evalForUs(config.playAsWhite);
          run.config = config.copyWith(
            minEvalCp: config.minEvalCp + rootEvalUs,
            maxEvalCp: config.maxEvalCp + rootEvalUs,
          );
        }
      }

      run.progress.reset(
        buildStartTotalNodes: tree.totalNodes,
        bestFirst: run.config.bestFirst,
        minProbability: run.config.minProbability,
      );

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
      final pruned = pruneEvalTooLow(tree, removedLines: prunedLines);
      lastPrunedTooLow = prunedLines;
      if (pruned > 0) {
        _log('Pruned $pruned eval-too-low nodes '
            '(${prunedLines.length} subtree roots)');
      }

      // Complete = frontier exhausted (neither cancelled nor finished early).
      tree.buildComplete = !run.isCancelled && !run.finishNow();

      _log('Build complete: ${tree.totalNodes} nodes, '
          'ply ${tree.maxPlyReached}, '
          '${run.stopwatch.elapsedMilliseconds}ms');
      _log('Stats: ${jsonEncode(_stats.toJson())}');

      return tree;
    } finally {
      _isBuilding = false;
      run.stopwatch.stop();
    }
  }

  // ── DB Explorer: build tree from PGN frequency map ─────────────────────

  /// Build a tree by parsing PGN files into a frequency map, then BFS-
  /// expanding from the root using move frequencies.  Matches C
  /// `tree_build_from_freqmap` + `tree_enrich_evals`.
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
    var nextNodeId = 1;
    final rootFen = config.startFen;
    final root = BuildTreeNode(
      fen: rootFen,
      moveSan: '',
      moveUci: '',
      ply: 0,
      isWhiteToMove: isWhiteToMove(rootFen),
      nodeId: nextNodeId++,
    );
    final tree = BuildTree(
      root: root,
      configSnapshot: config.toJson(),
    );
    tree.registerNode(root);
    root.cumulativeProbability = 1.0;
    root.searchPriority = 1.0;

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

    try {
      // Phase 0: Parse PGN files into frequency map (isolate)
      onStatusChanged?.call(
          'Parsing PGN files...', GenerationPhase.parsingPgn);
      final hasStartMoves = startMoves != null && startMoves.isNotEmpty;
      final pgnCustomFen = !_fenKeysEqual(config.startFen, kDefaultStartFen);
      final (freqMap, freqStats) = await parsePgnFiles(
        paths: config.pgnFilePaths,
        config: PgnFreqConfig(
          startFen: (!hasStartMoves && pgnCustomFen) ? config.startFen : null,
          startMoves: hasStartMoves ? startMoves : null,
          maxPly: config.maxPly,
          minElo: config.minElo,
        ),
        onProgress: (games, file) {
          onProgress(BuildProgress(
            totalNodes: 0,
            maxPlyConfig: config.maxPly,
            elapsedMs: run.stopwatch.elapsedMilliseconds,
          ));
        },
      );

      if (run.isCancelled) {
        throw const BuildCancelledException('Cancelled during PGN parsing.');
      }

      _log('Freq map: ${freqStats.totalGames} games, '
          '${freqStats.positions} positions, '
          '${freqStats.skippedElo} elo-filtered, '
          '${freqStats.parseErrors} movetext errors, '
          '${freqStats.fileReadErrors} file read errors');

      if (freqStats.totalGames == 0) {
        final parts = <String>[
          'No games parsed from ${config.pgnFilePaths.length} file(s).',
        ];
        if (freqStats.fileReadErrors > 0) {
          parts.add(
            '${freqStats.fileReadErrors} file(s) could not be read '
            '(check path and encoding).',
          );
        }
        if (freqStats.skippedElo > 0) {
          parts.add('${freqStats.skippedElo} skipped by Elo filter.');
        }
        if (freqStats.parseErrors > 0) {
          parts.add('${freqStats.parseErrors} movetext parse errors.');
        }
        throw StateError(parts.join(' '));
      }

      // Phase 1: BFS tree build from frequency map
      onStatusChanged?.call(
        'Building tree from ${freqStats.totalGames} games, '
        '${freqStats.positions} positions...',
        GenerationPhase.buildingTree,
      );

      final rootFreq = freqMap.get(rootFen);
      if (rootFreq != null) {
        root.totalGames = rootFreq.reachCount;
      }

      final queue = FrontierQueue(bestFirst: config.bestFirst);
      queue.add(root);

      while (!run.isCancelled && !run.finishNow() && queue.isNotEmpty) {
        await waitIfPaused();
        if (run.isCancelled) break;

        final node = queue.removeFirst();
        if (node.explored) continue;
        run.progress.onDequeue(
          node.ply,
          priority: effectiveSearchPriority(node),
          frontierSize: queue.length,
        );

        await _processDbExplorerNode(
          run: run,
          node: node,
          freqMap: freqMap,
          queue: queue,
        );
      }

      tree.buildComplete = !run.isCancelled && !run.finishNow();

      _log('DB Explorer tree: ${tree.totalNodes} nodes, '
          'ply ${tree.maxPlyReached}');

      // Phase 1.5: Eval enrichment.  Runs on finish-now too — a tree without
      // evals is useless to the selection phases downstream.
      if (!run.isCancelled) {
        onStatusChanged?.call(
          'Enriching evals (${tree.totalNodes} nodes)...',
          GenerationPhase.enrichingEvals,
        );

        await _evalResolver.evalCache.init();
        await _evalResolver.initProviders(config);

        if (config.usesStockfish || config.needsStockfish) {
          if (EngineLifecycle.instance.state != EngineState.generating) {
            await _pool.prepareForTreeBuild(config.resolvedEngineThreads);
          }
        }

        try {
          await _enrichEvals(run);
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

      _log('DB Explorer complete: ${tree.totalNodes} nodes, '
          '${run.stopwatch.elapsedMilliseconds}ms');
      _log('Stats: ${jsonEncode(_stats.toJson())}');

      return tree;
    } finally {
      _isBuilding = false;
      run.stopwatch.stop();
    }
  }

  Future<void> _processDbExplorerNode({
    required BuildRun run,
    required BuildTreeNode node,
    required PgnFreqMap freqMap,
    required FrontierQueue queue,
  }) async {
    final config = run.config;
    final tree = run.tree;

    if (node.ply >= config.maxPly) {
      node.explored = true;
      return;
    }
    // Fast: our-move sidelines whose frequency-share priority fell below
    // the floor are not worth expanding (priority ≤ cumulativeProbability).
    if (_belowSearchFloor(node, config)) {
      node.explored = true;
      return;
    }
    if (config.maxNodes > 0 && tree.totalNodes >= config.maxNodes) {
      node.explored = true;
      return;
    }

    final pos = freqMap.get(node.fen);
    if (pos == null || pos.moves.isEmpty) {
      node.explored = true;
      return;
    }

    node.totalGames = pos.reachCount;

    // Transposition detection
    if (_resolveTranspositionOrRegister(run, node, queue)) return;

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    final basePri = effectiveSearchPriority(node);

    int reach = pos.reachCount;
    if (reach == 0) {
      reach = pos.moves.fold(0, (sum, m) => sum + m.count);
    }

    if (isOurMove) {
      // Our move: add all moves from the frequency map.  Search priority
      // follows the DB frequency share so best-first explores our popular
      // moves first — cumulative probability stays undiscounted (our moves
      // are a choice, not chance).
      for (final m in pos.moves) {
        if (config.maxNodes > 0 && tree.totalNodes >= config.maxNodes) break;

        final childFen = playUciMove(node.fen, m.uci);
        if (childFen == null) continue;

        final san = m.san.isNotEmpty ? m.san : uciToSan(node.fen, m.uci);
        final child = run.makeChild(
          parent: node,
          fen: childFen,
          san: san,
          uci: m.uci,
        );
        if (child == null) continue;

        child.moveProbability = 1.0;
        child.cumulativeProbability = node.cumulativeProbability;
        child.searchPriority =
            reach > 0 ? basePri * (m.count / reach) : basePri;
        queue.add(child);
      }
    } else {
      // Opponent move: smoothed DB frequencies (Maia Dirichlet prior when
      // coverage is sparse), else raw frequencies with min-games/min-prob.
      if (reach == 0) {
        node.explored = true;
        return;
      }

      final maiaPolicy =
          await maiaPolicyForSmoothing(run, node.fen, reach);
      final smoothing = maiaPolicy.isNotEmpty;

      final candidates = smoothOpponentMoves(
        observed: [
          for (final m in pos.moves)
            ObservedMove(uci: m.uci, san: m.san, games: m.count),
        ],
        totalGames: reach,
        maiaPolicy: maiaPolicy,
        priorGames: smoothing ? config.maiaPriorGames : 0.0,
      );

      addOpponentChildren(
        run: run,
        node: node,
        candidates: candidates,
        smoothing: smoothing,
        minGames: config.dbMinGames,
        minMoveProb: config.dbMinProb,
        respectMaxNodes: true,
        emitProgressPerChild: false,
        onChild: queue.add,
      );
    }

    node.explored = true;

    run.emitNodeProgress(node);
  }

  /// Batch-evaluate tree nodes that lack engine evals.
  /// Matches C `tree_enrich_evals`: cache → external chain → Stockfish.
  Future<void> _enrichEvals(BuildRun run) async {
    final tree = run.tree;
    final config = run.config;

    final noEval = <BuildTreeNode>[];
    void collectNoEval(BuildTreeNode node) {
      if (!node.hasEngineEval) noEval.add(node);
      for (final child in node.children) {
        collectNoEval(child);
      }
    }

    collectNoEval(tree.root);

    if (noEval.isEmpty) return;

    _log('Enriching evals: ${noEval.length} nodes without eval');

    // Phase 1: external eval sources (cache + cdbdirect + ChessDB)
    int enriched = 0;
    for (final node in noEval) {
      await waitIfPaused();
      if (run.isCancelled) return;

      final gotEval = await _evalResolver.ensureEval(
        node,
        config,
        fenMap: run.fenMap,
        pool: _pool,
        dbOnly: true,
      );
      if (gotEval) enriched++;

      if (enriched % _externalEvalProgressInterval == 0) {
        run.emitNodeProgress(node);
      }
    }

    _log('External eval enrichment: $enriched / ${noEval.length} resolved');

    // Phase 2: Stockfish batch for remaining — one eval per unique FEN,
    // propagated to every node sharing that position.
    final stillNeed = noEval.where((n) => !n.hasEngineEval).toList();
    if (stillNeed.isNotEmpty && _pool.workerCount > 0) {
      _log('Stockfish enrichment: ${stillNeed.length} nodes remaining');

      final byFen = <String, List<BuildTreeNode>>{};
      for (final node in stillNeed) {
        (byFen[node.fen] ??= []).add(node);
      }

      int i = 0;
      for (final group in byFen.values) {
        await waitIfPaused();
        if (run.isCancelled) return;

        final node = group.first;
        await _evalResolver.ensureEval(
          node,
          config,
          fenMap: run.fenMap,
          pool: _pool,
        );

        if (node.hasEngineEval) {
          for (final other in group.skip(1)) {
            other.engineEvalCp = node.engineEvalCp;
          }
        }

        if (i++ % _stockfishEvalProgressInterval == 0) {
          run.emitNodeProgress(node);
        }
      }
    }

    final failed = noEval.where((n) => !n.hasEngineEval).length;
    _log('Eval enrichment done: $failed / ${noEval.length} still missing');
  }

  // ── BFS build loop ─────────────────────────────────────────────────────

  /// Collect frontier leaves for resume — matches C `resume_prepare_frontier`.
  static (List<BuildTreeNode> frontier, int minPly) prepareResumeFrontier(
    BuildTreeNode root,
  ) {
    final frontier = <BuildTreeNode>[];
    var minPly = _frontierMinPlySentinel;
    void walk(BuildTreeNode node) {
      if (node.children.isNotEmpty) {
        if (!node.explored) {
          frontier.add(node);
          if (node.ply < minPly) minPly = node.ply;
          return;
        }
        for (final child in node.children) {
          walk(child);
        }
        return;
      }
      if (!node.explored) {
        frontier.add(node);
        if (node.ply < minPly) minPly = node.ply;
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

    while (!run.isCancelled && !run.finishNow() && queue.isNotEmpty) {
      await waitIfPaused();
      if (run.isCancelled) return;
      final node = queue.removeFirst();
      run.progress.onDequeue(
        node.ply,
        priority: effectiveSearchPriority(node),
        frontierSize: queue.length,
      );
      await _processBuildNode(
        run: run,
        node: node,
        queue: queue,
        expander: expander,
      );
    }
  }

  /// Below-floor check shared by the main loop and the DB-explorer loop:
  /// discounted our-move alternatives whose priority fell below the floor
  /// are not worth budget (searchPriority ≤ cumulativeProbability always).
  static bool _belowSearchFloor(BuildTreeNode node, TreeBuildConfig config) {
    return node.cumulativeProbability < config.minProbability ||
        (config.bestFirst &&
            node.searchPriority >= 0.0 &&
            node.searchPriority < config.minProbability);
  }

  /// Transposition detection: when [node]'s position is already expanded
  /// elsewhere, register [node] as a transposition leaf (propagating a
  /// higher reach probability to the canonical subtree) and return true.
  /// Otherwise register [node] as the canonical expansion and return false.
  static bool _resolveTranspositionOrRegister(
    BuildRun run,
    BuildTreeNode node,
    FrontierQueue queue,
  ) {
    final canonical = run.fenMap.getCanonical(node.fen);
    if (canonical != null) {
      run.fenMap.addTransposition(node.fen, node);
      if (node.cumulativeProbability > canonical.cumulativeProbability) {
        propagateHigherCumP(
          canonical,
          node.cumulativeProbability,
          run.config.minProbability,
          queue,
        );
      }
      node.explored = true;
      return true;
    }
    run.fenMap.putCanonical(node.fen, node);
    return false;
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
    final owesAnswer = isOurMove &&
        node.ply > 0 &&
        node.children.isEmpty &&
        config.coverMinProb > 0.0 &&
        node.moveProbability >= config.coverMinProb;
    var coverageOnly = false;

    if (node.ply >= config.maxPly) {
      if (!owesAnswer) {
        if (!node.hasEngineEval && config.usesStockfish) {
          await _evalResolver.ensureEval(
            node,
            config,
            fenMap: run.fenMap,
            pool: _pool,
          );
        }
        node.explored = true;
        return;
      }
      coverageOnly = true;
    }
    if (_belowSearchFloor(node, config) && !coverageOnly) {
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
    // Our-move nodes skip this in stockfish mode — eval comes from MultiPV.
    // In maiaDbExplore mode, both sides need a DB eval before expanding.
    if (!isOurMove || !config.usesStockfish) {
      final gotEval = await _evalResolver.ensureEval(
        node,
        config,
        fenMap: run.fenMap,
        pool: _pool,
        dbOnly: !config.usesStockfish,
      );
      if (!gotEval && !config.usesStockfish) {
        node.explored = true;
        return;
      }
      if (evalWindowPrune(node, config)) {
        node.explored = true;
        return;
      }
    }

    // Transposition detection
    if (_resolveTranspositionOrRegister(run, node, queue)) return;

    if (isOurMove) {
      await expander.expandOurMove(node, queue, coverageOnly: coverageOnly);
    } else {
      await expander.expandOpponentMove(node, queue);
    }

    // Mark explored only after expansion finishes so pause/cancel mid-call
    // leaves the node resumable (explored=false, possibly partial children).
    if (!run.isCancelled) {
      node.explored = true;
    }
  }

  // ── Coverage sweep: no silent holes ─────────────────────────────────────

  /// End-of-build guarantee: every our-turn node in the final tree has at
  /// least one answer, carries an explicit pruneReason, or transposes to an
  /// answered position.  Dangling our-turn leaves (left by the node budget,
  /// the search floor, or maxPly parity) whose incoming opponent move clears
  /// [TreeBuildConfig.coverMinProb] get a coverage-only expansion; the rest
  /// are removed so their mass returns honestly to the expectimax tail term
  /// instead of ending exported lines on an unanswered opponent move.
  ///
  /// Returns the number of holes closed (answered + removed).
  Future<int> _coverageSweep(BuildRun run, NodeExpander expander) async {
    final tree = run.tree;
    final config = run.config;
    if (config.coverMinProb <= 0.0) return 0;

    final dangling = <BuildTreeNode>[];
    void collect(BuildTreeNode node) {
      for (final child in node.children) {
        collect(child);
      }
      if (node.ply == 0 || node.children.isNotEmpty) return;
      if (node.isWhiteToMove != config.playAsWhite) return; // tail-covered
      if (node.pruneReason != PruneReason.none) return; // explicit prune
      dangling.add(node);
    }

    collect(tree.root);
    if (dangling.isEmpty) return 0;

    // One expansion per position: group duplicates so the answer lands on
    // the canonical node and transposition leaves resolve through it.
    final groups = <String, List<BuildTreeNode>>{};
    for (final n in dangling) {
      (groups[canonicalizeFen(n.fen)] ??= []).add(n);
    }

    int answered = 0;
    int removed = 0;
    final throwawayQueue = FrontierQueue(bestFirst: false);

    for (final group in groups.values) {
      await waitIfPaused();
      if (run.isCancelled) break;

      final canonical = run.fenMap.getCanonical(group.first.fen);
      if (canonical != null && !group.contains(canonical)) {
        // The position lives elsewhere in the tree: answered there, or
        // explicitly pruned there — these leaves resolve via transposition.
        if (canonical.children.isNotEmpty ||
            canonical.pruneReason != PruneReason.none) {
          continue;
        }
      }

      // Representative: the registered canonical when it dangles here,
      // else the most-reachable member (registered for future resolution).
      final rep = (canonical != null && group.contains(canonical))
          ? canonical
          : (group..sort((a, b) =>
              b.cumulativeProbability.compareTo(a.cumulativeProbability)))
              .first;
      run.fenMap.putCanonical(rep.fen, rep);

      // The hole is worth answering if any path into this position carries
      // an opponent move at/above the coverage floor.
      var maxProb = 0.0;
      for (final n in group) {
        if (n.moveProbability > maxProb) maxProb = n.moveProbability;
      }
      for (final t in run.fenMap.getTranspositions(rep.fen)) {
        if (t.moveProbability > maxProb) maxProb = t.moveProbability;
      }

      if (maxProb >= config.coverMinProb) {
        final canExpand = config.buildMode == BuildMode.maiaDbExplore ||
            _pool.workerCount > 0;
        if (config.buildMode == BuildMode.maiaDbExplore) {
          await _evalResolver.ensureEval(
            rep,
            config,
            fenMap: run.fenMap,
            pool: _pool,
            dbOnly: true,
          );
        }
        if (canExpand) {
          await expander.expandOurMove(
            rep,
            throwawayQueue,
            coverageOnly: true,
          );
        }
        rep.explored = true;
        if (rep.children.isNotEmpty) {
          answered++;
          continue; // duplicates resolve via transposition
        }
        // Now explicitly flagged (eval window) — keep, it's not silent.
        if (rep.pruneReason != PruneReason.none) continue;
      }

      // Below the floor, or the expansion produced no answer: remove the
      // whole equivalence group so no line ends on an unanswered move.
      for (final n in group) {
        _removeLeaf(tree, n);
        removed++;
      }
    }

    if (answered > 0 || removed > 0) {
      _log('Coverage sweep: $answered holes answered, '
          '$removed uncovered leaves removed');
    }
    return answered + removed;
  }

  void _removeLeaf(BuildTree tree, BuildTreeNode node) {
    final parent = node.parent;
    if (parent == null) return;
    if (parent.children.remove(node)) {
      tree.nodeIndex.remove(node.nodeId);
      tree.totalNodes--;
    }
  }

  bool _fenKeysEqual(String fenA, String fenB) {
    return canonicalizeFen(fenA) == canonicalizeFen(fenB);
  }
}
