/// Two-phase tree builder — builds a persistent [BuildTree] with engine
/// evaluations on every node, matching the C tree_builder algorithm.
///
/// Phase 1 (this service): BFS build (FIFO queue) with constant MultiPV at
/// each ply our-move nodes, single-source opponent moves (Maia OR Lichess),
/// eval-window pruning, and transposition detection — matches C tree_builder.
///
/// Phase 2 (separate calculators): ease, expectimax, and repertoire
/// selection run on the completed tree.
library;

import 'dart:async';
import 'dart:collection' show Queue;

import 'package:flutter/foundation.dart';

import '../models/build_tree_node.dart';
import '../models/explorer_response.dart';
import '../utils/chess_utils.dart' show playUciMove, uciToSan;
import '../utils/fen_utils.dart';
import 'engine/stockfish_pool.dart';
import 'engine/engine_lifecycle.dart';
import 'eval/chessdb_api_provider.dart';
import 'generation/fen_map.dart';
import 'generation/generation_config.dart';
import 'generation/pgn_freq_map.dart';
import 'generation/tree_build_progress.dart';
import 'generation/tree_eval_resolver.dart';
import 'maia_factory.dart';
import 'maia_service.dart';

class TreeBuildService {
  final StockfishPool _pool = StockfishPool();
  final TreeEvalResolver _evalResolver = TreeEvalResolver();

  static const double _pvInjectEpsilon = 0.01;
  static const int _frontierMinPlySentinel = 1 << 30;
  static const int _externalEvalProgressInterval = 50;
  static const int _stockfishEvalProgressInterval = 10;

  bool _isBuilding = false;
  bool _isPaused = false;
  Completer<void>? _pauseCompleter;
  int _nextNodeId = 1;

  late BuildStats _stats;
  Stopwatch _buildSw = Stopwatch();

  final TreeBuildProgressTracker _progress = TreeBuildProgressTracker();

  BuildStats get buildStats => _stats;
  ChessDbApiProvider? get chessDbApiProvider =>
      _evalResolver.chessDbApiProvider;

  /// True while Phase 1 BFS is running ([build] in progress).
  bool get isBuilding => _isBuilding;

  /// Phase 1 active-build elapsed time; stops advancing while [pauseBuild] holds.
  int get buildElapsedMs => _buildSw.elapsedMilliseconds;

  BuildTree? _currentTree;
  BuildTree? get currentTree => _currentTree;

  bool get isPaused => _isPaused;

  void pauseBuild() {
    if (!_isBuilding || _isPaused) return;
    _isPaused = true;
    _pauseCompleter = Completer<void>();
    _buildSw.stop();
  }

  void resumeBuild() {
    if (!_isPaused) return;
    _isPaused = false;
    _buildSw.start();
    _pauseCompleter?.complete();
    _pauseCompleter = null;
  }

  void _log(String msg) {
    if (kDebugMode) debugPrint('[TreeBuild] $msg');
  }

  // ── Public API ─────────────────────────────────────────────────────────

  Future<BuildTree> build({
    required TreeBuildConfig config,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
    BuildTree? existingTree,
  }) async {
    _stats = BuildStats();
    _evalResolver.stats = _stats;
    _buildSw = Stopwatch()..start();
    _progress.reset(buildStartTotalNodes: 0);

    var cfg = config;
    _isPaused = false;
    _pauseCompleter = null;

    await Future.wait([
      if (cfg.usesStockfish &&
          EngineLifecycle().state != EngineState.generating)
        _pool.prepareForTreeBuild(cfg.resolvedEngineThreads)
      else if (cfg.usesStockfish)
        Future.value()
      else
        Future.value(),
      _evalResolver.evalCache.init(),
    ]);
    await _evalResolver.initProviders(cfg);
    if (cfg.usesStockfish && _pool.workerCount == 0) {
      throw StateError('No engine workers available');
    }

    BuildTree tree;
    if (existingTree != null) {
      tree = existingTree;
      _nextNodeId = _findMaxNodeId(tree.root) + 1;
      if (tree.nodeIndex.isEmpty) {
        tree.computeMetadata();
      }
    } else {
      _evalResolver.reset();
      _nextNodeId = 1;
      final rootFen = cfg.startFen;
      final whiteToMove = isWhiteToMove(rootFen);
      final root = BuildTreeNode(
        fen: rootFen,
        moveSan: '',
        moveUci: '',
        ply: 0,
        isWhiteToMove: whiteToMove,
        nodeId: _nextNodeId++,
      );
      tree = BuildTree(
        root: root,
        configSnapshot: cfg.toJson(),
      );
      tree.registerNode(root);
    }

    _currentTree = tree;
    _isBuilding = true;

    if (cfg.relativeEval) {
      final rootFenMap = FenMap();
      final gotEval = await _evalResolver.ensureEval(
        tree.root,
        cfg,
        fenMap: rootFenMap,
        pool: _pool,
        dbOnly: !cfg.usesStockfish,
      );
      if (!gotEval && !cfg.usesStockfish) {
        throw StateError(
          'Root position has no database eval — enable an eval source '
          '(local ChessDB, cdbdirect, or ChessDB API)',
        );
      }
      if (tree.root.hasEngineEval) {
        final rootEvalUs = tree.root.evalForUs(cfg.playAsWhite);
        cfg = cfg.copyWith(
          minEvalCp: cfg.minEvalCp + rootEvalUs,
          maxEvalCp: cfg.maxEvalCp + rootEvalUs,
        );
      }
    }

    _progress.reset(buildStartTotalNodes: tree.totalNodes);

    final fenMap = FenMap();

    try {
      await _buildBfsLoop(
        tree: tree,
        config: cfg,
        fenMap: fenMap,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
    } finally {
      fenMap.clear();
      await _evalResolver.teardownProviders();
    }

    final pruned = _pruneEvalTooLow(tree);
    if (pruned > 0) {
      _log('Pruned $pruned eval-too-low nodes');
    }

    tree.buildComplete = _isBuilding;
    _isBuilding = false;
    _buildSw.stop();

    _log('Build complete: ${tree.totalNodes} nodes, '
        'ply ${tree.maxPlyReached}, '
        '${_buildSw.elapsedMilliseconds}ms');

    return tree;
  }

  void stopBuild() {
    _isBuilding = false;
    if (_isPaused) {
      _isPaused = false;
      _pauseCompleter?.complete();
      _pauseCompleter = null;
    }
  }

  // ── DB Explorer: build tree from PGN frequency map ─────────────────────

  /// Build a tree by parsing PGN files into a frequency map, then BFS-
  /// expanding from the root using move frequencies.  Matches C
  /// `tree_build_from_freqmap` + `tree_enrich_evals`.
  Future<BuildTree> buildFromPgnFreqMap({
    required TreeBuildConfig config,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
    void Function(String status)? onStatusChanged,
  }) async {
    _stats = BuildStats();
    _evalResolver.stats = _stats;
    _buildSw = Stopwatch()..start();
    _progress.reset(buildStartTotalNodes: 0);
    _isPaused = false;
    _pauseCompleter = null;

    if (config.pgnFilePaths.isEmpty) {
      throw StateError('DB Explorer requires at least one PGN file.');
    }

    // Phase 0: Parse PGN files into frequency map (isolate)
    onStatusChanged?.call('Parsing PGN files...');
    final (freqMap, freqStats) = await parsePgnFiles(
      paths: config.pgnFilePaths,
      config: PgnFreqConfig(
        startFen: config.startFen,
        maxPly: config.maxPly,
        minElo: config.minElo,
      ),
      onProgress: (games, file) {
        onProgress(BuildProgress(
          totalNodes: 0,
          maxPlyConfig: config.maxPly,
          elapsedMs: _buildSw.elapsedMilliseconds,
        ));
      },
    );

    if (isCancelled()) {
      _buildSw.stop();
      throw StateError('Cancelled during PGN parsing.');
    }

    _log('Freq map: ${freqStats.totalGames} games, '
        '${freqStats.positions} positions, '
        '${freqStats.skippedElo} elo-filtered, '
        '${freqStats.parseErrors} errors');

    if (freqStats.totalGames == 0) {
      _buildSw.stop();
      throw StateError(
        'No games parsed from ${config.pgnFilePaths.length} file(s). '
        '${freqStats.skippedElo > 0 ? "${freqStats.skippedElo} skipped by Elo filter. " : ""}'
        '${freqStats.parseErrors > 0 ? "${freqStats.parseErrors} parse errors." : ""}',
      );
    }

    // Phase 1: BFS tree build from frequency map
    onStatusChanged?.call(
      'Building tree from ${freqStats.totalGames} games, '
      '${freqStats.positions} positions...',
    );

    _nextNodeId = 1;
    final rootFen = config.startFen;
    final whiteToMove = isWhiteToMove(rootFen);
    final root = BuildTreeNode(
      fen: rootFen,
      moveSan: '',
      moveUci: '',
      ply: 0,
      isWhiteToMove: whiteToMove,
      nodeId: _nextNodeId++,
    );
    final tree = BuildTree(
      root: root,
      configSnapshot: config.toJson(),
    );
    tree.registerNode(root);
    _currentTree = tree;
    _isBuilding = true;

    final rootFreq = freqMap.get(rootFen);
    if (rootFreq != null) {
      root.totalGames = rootFreq.reachCount;
    }
    root.cumulativeProbability = 1.0;

    final fenMap = FenMap();
    final queue = Queue<BuildTreeNode>();
    queue.add(root);

    while (_isBuilding && !isCancelled() && queue.isNotEmpty) {
      if (_isPaused && _pauseCompleter != null) {
        await _pauseCompleter!.future;
        if (!_isBuilding || isCancelled()) break;
      }

      final node = queue.removeFirst();
      if (node.explored) continue;

      _processDbExplorerNode(
        tree: tree,
        node: node,
        freqMap: freqMap,
        config: config,
        fenMap: fenMap,
        queue: queue,
        onProgress: onProgress,
      );
    }

    tree.buildComplete = _isBuilding && !isCancelled();

    _log('DB Explorer tree: ${tree.totalNodes} nodes, '
        'ply ${tree.maxPlyReached}');

    // Phase 1.5: Eval enrichment
    if (_isBuilding && !isCancelled()) {
      onStatusChanged?.call('Enriching evals (${tree.totalNodes} nodes)...');

      await _evalResolver.evalCache.init();
      await _evalResolver.initProviders(config);

      if (config.usesStockfish || config.needsStockfish) {
        if (EngineLifecycle().state != EngineState.generating) {
          await _pool.prepareForTreeBuild(config.resolvedEngineThreads);
        }
      }

      try {
        await _enrichEvals(
          tree: tree,
          config: config,
          fenMap: fenMap,
          isCancelled: isCancelled,
          onProgress: onProgress,
        );
      } finally {
        fenMap.clear();
        await _evalResolver.teardownProviders();
      }
    }

    _isBuilding = false;
    _buildSw.stop();

    _log('DB Explorer complete: ${tree.totalNodes} nodes, '
        '${_buildSw.elapsedMilliseconds}ms');

    return tree;
  }

  void _processDbExplorerNode({
    required BuildTree tree,
    required BuildTreeNode node,
    required PgnFreqMap freqMap,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required Queue<BuildTreeNode> queue,
    required void Function(BuildProgress) onProgress,
  }) {
    if (node.ply >= config.maxPly) {
      node.explored = true;
      return;
    }
    if (node.cumulativeProbability < config.minProbability) {
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
    final canonical = fenMap.getCanonical(node.fen);
    if (canonical != null) {
      fenMap.addTransposition(node.fen, node);
      node.explored = true;
      return;
    }
    fenMap.putCanonical(node.fen, node);

    final isOurMove = node.isWhiteToMove == config.playAsWhite;

    if (isOurMove) {
      // Our move: add all moves from the frequency map
      for (final m in pos.moves) {
        if (config.maxNodes > 0 && tree.totalNodes >= config.maxNodes) break;

        final childFen = playUciMove(node.fen, m.uci);
        if (childFen == null) continue;

        final san = m.san.isNotEmpty ? m.san : uciToSan(node.fen, m.uci);
        final child = _makeChild(
          parent: node,
          fen: childFen,
          san: san,
          uci: m.uci,
          tree: tree,
        );
        if (child == null) continue;

        child.moveProbability = 1.0;
        child.cumulativeProbability = node.cumulativeProbability;
        queue.add(child);
      }
    } else {
      // Opponent move: filter by min-games and min-prob
      final filtered = freqMap.filteredMoves(
        pos,
        minGames: config.dbMinGames,
        minProb: config.dbMinProb,
      );

      int reach = pos.reachCount;
      if (reach == 0) {
        reach = pos.moves.fold(0, (sum, m) => sum + m.count);
      }
      if (reach == 0) {
        node.explored = true;
        return;
      }

      for (final m in filtered) {
        if (config.maxNodes > 0 && tree.totalNodes >= config.maxNodes) break;

        final prob = m.count / reach;
        final newCumul = node.cumulativeProbability * prob;
        if (newCumul < config.minProbability) continue;

        final childFen = playUciMove(node.fen, m.uci);
        if (childFen == null) continue;

        final san = m.san.isNotEmpty ? m.san : uciToSan(node.fen, m.uci);
        final child = _makeChild(
          parent: node,
          fen: childFen,
          san: san,
          uci: m.uci,
          tree: tree,
        );
        if (child == null) continue;

        child.moveProbability = prob;
        child.cumulativeProbability = newCumul;
        queue.add(child);
      }
    }

    node.explored = true;

    _progress.emitProgress(
      tree,
      node.ply,
      node.fen,
      onProgress,
      config.maxPly,
      buildSw: _buildSw,
    );
  }

  /// Batch-evaluate tree nodes that lack engine evals.
  /// Matches C `tree_enrich_evals`: cache → external chain → Stockfish.
  Future<void> _enrichEvals({
    required BuildTree tree,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
  }) async {
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
      if (isCancelled()) return;

      final gotEval = await _evalResolver.ensureEval(
        node,
        config,
        fenMap: fenMap,
        pool: _pool,
        dbOnly: true,
      );
      if (gotEval) enriched++;

      if (enriched % _externalEvalProgressInterval == 0) {
        _progress.emitProgress(
          tree,
          node.ply,
          node.fen,
          onProgress,
          config.maxPly,
          buildSw: _buildSw,
        );
      }
    }

    _log('External eval enrichment: $enriched / ${noEval.length} resolved');

    // Phase 2: Stockfish batch for remaining
    final stillNeed = noEval.where((n) => !n.hasEngineEval).toList();
    if (stillNeed.isNotEmpty && _pool.workerCount > 0) {
      _log('Stockfish enrichment: ${stillNeed.length} nodes remaining');

      // Deduplicate by FEN
      final uniqueFens = <String>{};
      final toEval = <BuildTreeNode>[];
      for (final node in stillNeed) {
        if (uniqueFens.add(node.fen)) {
          toEval.add(node);
        }
      }

      for (int i = 0; i < toEval.length; i++) {
        if (isCancelled()) return;

        final node = toEval[i];
        await _evalResolver.ensureEval(
          node,
          config,
          fenMap: fenMap,
          pool: _pool,
        );

        // Propagate eval to other nodes with the same FEN
        if (node.hasEngineEval) {
          for (final other in stillNeed) {
            if (!other.hasEngineEval && other.fen == node.fen) {
              other.engineEvalCp = node.engineEvalCp;
            }
          }
        }

        if (i % _stockfishEvalProgressInterval == 0) {
          _progress.emitProgress(
            tree,
            node.ply,
            node.fen,
            onProgress,
            config.maxPly,
            buildSw: _buildSw,
          );
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

  Future<void> _buildBfsLoop({
    required BuildTree tree,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
  }) async {
    final queue = Queue<BuildTreeNode>();

    final fastResume = tree.totalNodes > 1 && tree.root.children.isNotEmpty;
    if (fastResume) {
      final (frontier, minPly) = prepareResumeFrontier(tree.root);
      if (frontier.isEmpty) {
        _log('No frontier positions to expand');
        return;
      }
      frontier.sort((a, b) => a.ply.compareTo(b.ply));
      queue.addAll(frontier);
      _progress.initForResume(minFrontierPly: minPly);
    } else {
      queue.add(tree.root);
    }

    while (_isBuilding && !isCancelled() && queue.isNotEmpty) {
      if (_isPaused && _pauseCompleter != null) {
        await _pauseCompleter!.future;
        if (!_isBuilding || isCancelled()) return;
      }
      final node = queue.removeFirst();
      _progress.onDequeue(node.ply);
      await _processBuildNode(
        tree: tree,
        node: node,
        config: config,
        fenMap: fenMap,
        isCancelled: isCancelled,
        onProgress: onProgress,
        queue: queue,
      );
    }
  }

  Future<void> _processBuildNode({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
    required Queue<BuildTreeNode> queue,
  }) async {
    if (!_isBuilding || isCancelled()) return;

    // Pause gate: if paused, wait until resumed or cancelled
    if (_isPaused && _pauseCompleter != null) {
      await _pauseCompleter!.future;
      if (!_isBuilding || isCancelled()) return;
    }

    if (node.ply >= config.maxPly) {
      if (!node.hasEngineEval && config.usesStockfish) {
        await _evalResolver.ensureEval(
          node,
          config,
          fenMap: fenMap,
          pool: _pool,
        );
      }
      node.explored = true;
      return;
    }
    if (node.cumulativeProbability < config.minProbability) return;
    if (config.maxNodes > 0 && tree.totalNodes >= config.maxNodes) return;

    _progress.emitProgress(
      tree,
      node.ply,
      node.fen,
      onProgress,
      config.maxPly,
      buildSw: _buildSw,
      fromDequeue: true,
    );

    // Resume: fully expanded in a prior session — enqueue children only.
    if (node.children.isNotEmpty && node.explored) {
      fenMap.putCanonical(node.fen, node);
      for (final child in node.children) {
        if (!_isBuilding || isCancelled()) break;
        queue.add(child);
      }
      return;
    }
    if (node.explored) return;

    final isOurMove = node.isWhiteToMove == config.playAsWhite;

    // Opponent-move nodes: ensure eval + window prune BEFORE expansion.
    // Our-move nodes skip this in stockfish mode — eval comes from MultiPV.
    // In maiaDbExplore mode, both sides need a DB eval before expanding.
    if (!isOurMove || !config.usesStockfish) {
      final gotEval = await _evalResolver.ensureEval(
        node,
        config,
        fenMap: fenMap,
        pool: _pool,
        dbOnly: !config.usesStockfish,
      );
      if (!gotEval && !config.usesStockfish) {
        node.explored = true;
        return;
      }
      if (node.hasEngineEval) {
        final evalUs = node.evalForUs(config.playAsWhite);
        if (evalUs > config.maxEvalCp) {
          node.explored = true;
          node.pruneReason = PruneReason.evalTooHigh;
          node.pruneEvalCp = evalUs;
          return;
        }
        if (evalUs < config.minEvalCp) {
          node.explored = true;
          node.pruneReason = PruneReason.evalTooLow;
          node.pruneEvalCp = evalUs;
          return;
        }
      }
    }

    // Transposition detection
    final canonical = fenMap.getCanonical(node.fen);
    if (canonical != null) {
      fenMap.addTransposition(node.fen, node);
      node.explored = true;
      return;
    }
    fenMap.putCanonical(node.fen, node);

    if (isOurMove) {
      if (config.buildMode == BuildMode.maiaDbExplore) {
        await _buildOurMoveMaiaDb(
          tree: tree,
          node: node,
          config: config,
          isCancelled: isCancelled,
          onProgress: onProgress,
          queue: queue,
        );
      } else {
        await _buildOurMove(
          tree: tree,
          node: node,
          config: config,
          fenMap: fenMap,
          isCancelled: isCancelled,
          onProgress: onProgress,
          queue: queue,
        );
      }
    } else {
      await _buildOpponentMove(
        tree: tree,
        node: node,
        config: config,
        fenMap: fenMap,
        isCancelled: isCancelled,
        onProgress: onProgress,
        queue: queue,
      );
    }

    // Mark explored only after expansion finishes so pause/cancel mid-call
    // leaves the node resumable (explored=false, possibly partial children).
    if (_isBuilding && !isCancelled()) {
      node.explored = true;
    }
  }

  // ── Our move (Maia + DB): top-N Maia candidates, DB evals only ───────

  Future<void> _buildOurMoveMaiaDb({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
    required Queue<BuildTreeNode> queue,
  }) async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
      _log('Maia unavailable — cannot run maiaDbExplore mode');
      return;
    }

    // Window prune using DB eval set in _processBuildNode.
    if (node.hasEngineEval) {
      final evalUs = node.evalForUs(config.playAsWhite);
      if (evalUs > config.maxEvalCp) {
        node.pruneReason = PruneReason.evalTooHigh;
        node.pruneEvalCp = evalUs;
        return;
      }
      if (evalUs < config.minEvalCp) {
        node.pruneReason = PruneReason.evalTooLow;
        node.pruneEvalCp = evalUs;
        return;
      }
    }

    final sw = Stopwatch()..start();
    final MaiaResult maiaResult;
    try {
      maiaResult = await MaiaFactory.instance!.evaluate(
        node.fen,
        config.maiaElo,
      );
    } catch (e) {
      _log('Maia eval failed: $e');
      return;
    }
    _stats.maiaEvals++;
    _stats.maiaTotalMs += sw.elapsedMilliseconds;
    if (maiaResult.policy.isEmpty) return;

    final sortedMoves = maiaResult.policy.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final maxCandidates = config.ourMultipv.clamp(1, 16);
    final bestCpWhite = node.hasEngineEval
        ? (node.isWhiteToMove ? node.engineEvalCp! : -node.engineEvalCp!)
        : null;

    int added = 0;
    for (final entry in sortedMoves) {
      if (added >= maxCandidates) break;
      final uci = entry.key;
      final prob = entry.value;
      if (prob < config.maiaMinProb) continue;

      final childFen = playUciMove(node.fen, uci);
      if (childFen == null) continue;

      // Child eval from DB only — skip candidates with no database coverage.
      final childEval = await _evalResolver.lookupDbEvalWhite(childFen, config);
      if (childEval == null) continue;

      final childIsWhite = isWhiteToMove(childFen);
      final childCpWhite = childEval.$1;

      if (bestCpWhite != null) {
        final evalLoss = bestCpWhite - childCpWhite;
        if (evalLoss > config.maxEvalLossCp) continue;
      }

      final san = uciToSan(node.fen, uci);
      final child = _makeChild(
        parent: node,
        fen: childFen,
        san: san,
        uci: uci,
        tree: tree,
      );
      if (child == null) continue;

      child.moveProbability = 1.0;
      child.cumulativeProbability = node.cumulativeProbability;
      child.maiaFrequency = prob;
      child.engineEvalCp = childIsWhite ? childCpWhite : -childCpWhite;
      _evalResolver.cacheEvalWhite(childFen, childCpWhite, childEval.$2);

      added++;
      _progress.emitProgress(
        tree,
        child.ply,
        child.fen,
        onProgress,
        config.maxPly,
        buildSw: _buildSw,
      );
    }

    for (final child in List.of(node.children)) {
      if (!_isBuilding || isCancelled()) break;
      queue.add(child);
    }
  }

  // ── Our move: Stockfish MultiPV → eval filter → enqueue children ───────

  Future<void> _buildOurMove({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
    required Queue<BuildTreeNode> queue,
  }) async {
    final mpvCount = config.ourMultipv;
    final whiteToMove = isWhiteToMove(node.fen);

    final sw = Stopwatch()..start();
    final discovery = await _pool.discoverMoves(
      fen: node.fen,
      depth: config.evalDepth,
      multiPv: mpvCount,
      isWhiteToMove: whiteToMove,
    );
    _stats.sfMultipvCalls++;
    _stats.sfMultipvMs += sw.elapsedMilliseconds;

    if (discovery.lines.isEmpty) return;

    // Set node eval from top line
    if (!node.hasEngineEval) {
      final topCp = discovery.lines.first.effectiveCp;
      final stmCp = whiteToMove ? topCp : -topCp;
      node.engineEvalCp = stmCp;
      _evalResolver.cacheEvalWhite(node.fen, topCp, config.evalDepth);
    }

    // Eval-window pruning (deferred from _processBuildNode so the eval
    // comes from MultiPV line 0, avoiding an extra single-PV call).
    if (node.hasEngineEval) {
      final evalUs = node.evalForUs(config.playAsWhite);
      if (evalUs > config.maxEvalCp) {
        node.pruneReason = PruneReason.evalTooHigh;
        node.pruneEvalCp = evalUs;
        return;
      }
      if (evalUs < config.minEvalCp) {
        node.pruneReason = PruneReason.evalTooLow;
        node.pruneEvalCp = evalUs;
        return;
      }
    }

    // Lichess enrichment for SAN + win rates at our-move nodes.
    // Matches C: queried when `!maia_only` (Lichess is the opponent
    // source, so the explorer data is available anyway).
    ExplorerResponse? lichess;
    if (!config.maiaOnly) {
      lichess = await _evalResolver.getDbData(node.fen, config);
    }

    if (lichess != null) {
      final totalW = lichess.moves.fold(0, (s, m) => s + m.white);
      final totalB = lichess.moves.fold(0, (s, m) => s + m.black);
      final totalD = lichess.moves.fold(0, (s, m) => s + m.draws);
      node.setLichessStats(totalW, totalB, totalD);
    }

    // Filter candidates by eval loss (direction depends on STM)
    final bestCp = discovery.lines.first.effectiveCp;

    for (final line in discovery.lines) {
      if (line.moveUci.isEmpty) continue;
      final evalLoss =
          whiteToMove ? bestCp - line.effectiveCp : line.effectiveCp - bestCp;
      if (evalLoss > config.maxEvalLossCp) continue;

      final childFen = playUciMove(node.fen, line.moveUci);
      if (childFen == null) continue;

      // Dedup by FEN (catches castling representation mismatches)
      if (node.children.any((c) => c.fen == childFen)) continue;

      // Get SAN from Lichess data or compute it
      String san = line.moveUci;
      if (lichess != null) {
        final lichessMove =
            lichess.moves.where((m) => m.uci == line.moveUci).firstOrNull;
        if (lichessMove != null) {
          san = lichessMove.san;
        }
      }
      if (san == line.moveUci) {
        san = uciToSan(node.fen, line.moveUci);
      }

      final childIsWhite = isWhiteToMove(childFen);
      final childEvalStm = whiteToMove ? -line.effectiveCp : line.effectiveCp;

      final child = _makeChild(
        parent: node,
        fen: childFen,
        san: san,
        uci: line.moveUci,
        tree: tree,
      );
      if (child == null) continue;

      child.moveProbability = 1.0;
      child.cumulativeProbability = node.cumulativeProbability;
      child.engineEvalCp = childEvalStm;
      _evalResolver.cacheEvalWhite(childFen,
          childIsWhite ? childEvalStm : -childEvalStm, config.evalDepth);

      // Enrich with Lichess stats
      if (lichess != null) {
        final lm =
            lichess.moves.where((m) => m.uci == line.moveUci).firstOrNull;
        if (lm != null) {
          child.setLichessStats(lm.white, lm.black, lm.draws);
        }
      }

      // Line 0 only: stash engine's preferred opponent reply on the child
      // (opponent-to-move position after our best move).
      if (line.pvNumber == 1 && line.pv.length >= 2) {
        child.pvContinuationMove = line.pv[1];
      }

      _progress.emitProgress(
        tree,
        child.ply,
        child.fen,
        onProgress,
        config.maxPly,
        buildSw: _buildSw,
      );
    }

    // Populate maia_frequency on our-move children.  C gates this on
    // `populate_maia_frequency` (novelty > 0 || find_traps); Dart always
    // populates when Maia is available since the data is useful for both
    // novelty scoring and trap-line display.
    if (MaiaFactory.isAvailable &&
        MaiaFactory.instance != null &&
        node.children.isNotEmpty) {
      try {
        final maiaResult = await MaiaFactory.instance!.evaluate(
          node.fen,
          config.maiaElo,
        );
        _stats.maiaEvals++;
        if (maiaResult.policy.isNotEmpty) {
          for (final child in node.children) {
            final freq = maiaResult.policy[child.moveUci];
            if (freq != null) {
              child.maiaFrequency = freq;
            }
          }
        }
      } catch (_) {
        // Maia frequency is best-effort
      }
    }

    for (final child in List.of(node.children)) {
      if (!_isBuilding || isCancelled()) break;
      queue.add(child);
    }
  }

  // ── Opponent move: single source (Maia OR Lichess) → enqueue children ──

  Future<void> _buildOpponentMove({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
    required Queue<BuildTreeNode> queue,
  }) async {
    if (config.maiaOnly) {
      await _addOpponentChildrenFromMaia(
        tree: tree,
        node: node,
        config: config,
        onProgress: onProgress,
        maiaForInject: true,
      );
    } else {
      await _addOpponentChildrenFromLichess(
        tree: tree,
        node: node,
        config: config,
        onProgress: onProgress,
      );
      // Fall back to Maia when the Lichess DB has no data for this position
      if (node.children.isEmpty) {
        await _addOpponentChildrenFromMaia(
          tree: tree,
          node: node,
          config: config,
          onProgress: onProgress,
          maiaForInject: true,
        );
      } else {
        await _maybeInjectPvContinuation(
          tree: tree,
          node: node,
          config: config,
          onProgress: onProgress,
        );
      }
    }

    if (node.children.isEmpty) return;

    // Probabilities are kept RAW (Σ pᵢ ≤ 1).  The expectimax tail term
    // accounts for uncovered mass; renormalizing would silently bias V.

    // Enqueue children — eval-window check + ensureEval happen in
    // _processBuildNode, so no separate batch-eval pass is needed here.
    for (final child in List.of(node.children)) {
      if (!_isBuilding || isCancelled()) break;
      queue.add(child);
    }
  }

  Future<void> _addOpponentChildrenFromLichess({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required void Function(BuildProgress) onProgress,
  }) async {
    final response = await _evalResolver.getDbData(node.fen, config);
    if (response == null || response.totalGames == 0) return;

    final totalW = response.moves.fold(0, (s, m) => s + m.white);
    final totalB = response.moves.fold(0, (s, m) => s + m.black);
    final totalD = response.moves.fold(0, (s, m) => s + m.draws);
    node.setLichessStats(totalW, totalB, totalD);

    int childrenAdded = 0;
    double massCovered = 0.0;
    final massTarget = config.oppMassTarget;

    for (final move in response.moves) {
      if (move.total < config.minGames) continue;
      if (config.oppMaxChildren > 0 && childrenAdded >= config.oppMaxChildren) {
        break;
      }
      if (massTarget > 0.0 && massCovered >= massTarget) break;

      final prob = move.playFraction;
      final newCumul = node.cumulativeProbability * prob;
      if (newCumul < config.minProbability) continue;

      final childFen = playUciMove(node.fen, move.uci);
      if (childFen == null) continue;

      final child = _makeChild(
        parent: node,
        fen: childFen,
        san: move.san,
        uci: move.uci,
        tree: tree,
      );
      if (child == null) continue;

      child.moveProbability = prob;
      child.cumulativeProbability = newCumul;
      child.setLichessStats(move.white, move.black, move.draws);
      childrenAdded++;
      massCovered += prob;

      _progress.emitProgress(
        tree,
        child.ply,
        child.fen,
        onProgress,
        config.maxPly,
        buildSw: _buildSw,
      );
    }
  }

  Future<void> _addOpponentChildrenFromMaia({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required void Function(BuildProgress) onProgress,
    bool maiaForInject = false,
  }) async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) return;

    final sw = Stopwatch()..start();
    final MaiaResult maiaResult;
    try {
      maiaResult = await MaiaFactory.instance!.evaluate(
        node.fen,
        config.maiaElo,
      );
    } catch (e) {
      _log('Maia eval failed: $e');
      return;
    }
    _stats.maiaEvals++;
    _stats.maiaTotalMs += sw.elapsedMilliseconds;
    if (maiaResult.policy.isEmpty) {
      if (maiaForInject) {
        await _maybeInjectPvContinuation(
          tree: tree,
          node: node,
          config: config,
          onProgress: onProgress,
        );
      }
      return;
    }

    final sortedMoves = maiaResult.policy.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    int childrenAdded = 0;
    double massCovered = 0.0;
    final massTarget = config.oppMassTarget;

    for (final entry in sortedMoves) {
      final uci = entry.key;
      final prob = entry.value;
      if (prob < config.maiaMinProb) continue;
      if (config.oppMaxChildren > 0 && childrenAdded >= config.oppMaxChildren) {
        break;
      }
      if (massTarget > 0.0 && massCovered >= massTarget) break;

      final newCumul = node.cumulativeProbability * prob;
      if (newCumul < config.minProbability) continue;

      final childFen = playUciMove(node.fen, uci);
      if (childFen == null) continue;

      final san = uciToSan(node.fen, uci);
      final child = _makeChild(
        parent: node,
        fen: childFen,
        san: san,
        uci: uci,
        tree: tree,
      );
      if (child == null) continue;

      child.moveProbability = prob;
      child.cumulativeProbability = newCumul;
      childrenAdded++;
      massCovered += prob;

      _progress.emitProgress(
        tree,
        child.ply,
        child.fen,
        onProgress,
        config.maxPly,
        buildSw: _buildSw,
      );
    }

    if (maiaForInject) {
      await _maybeInjectPvContinuation(
        tree: tree,
        node: node,
        config: config,
        onProgress: onProgress,
        maiaPolicy: maiaResult.policy,
      );
    }
  }

  Future<void> _maybeInjectPvContinuation({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required void Function(BuildProgress) onProgress,
    Map<String, double>? maiaPolicy,
  }) async {
    final pvUci = node.pvContinuationMove;
    if (pvUci == null || pvUci.isEmpty) return;

    if (node.children.any((c) => c.moveUci == pvUci)) return;

    final childFen = playUciMove(node.fen, pvUci);
    if (childFen == null) return;

    final san = uciToSan(node.fen, pvUci);
    final child = _makeChild(
      parent: node,
      fen: childFen,
      san: san,
      uci: pvUci,
      tree: tree,
    );
    if (child == null) return;

    double prob = maiaPolicy?[pvUci] ?? -1.0;
    if (prob < 0 && MaiaFactory.isAvailable && MaiaFactory.instance != null) {
      try {
        final maiaResult = await MaiaFactory.instance!.evaluate(
          node.fen,
          config.maiaElo,
        );
        _stats.maiaEvals++;
        prob = maiaResult.policy[pvUci] ?? -1.0;
      } catch (_) {
        // Best-effort Maia lookup for injected move probability.
      }
    }
    if (prob < 0) prob = _pvInjectEpsilon;

    child.moveProbability = prob;
    child.cumulativeProbability = node.cumulativeProbability * prob;
    child.engineInjected = true;

    _progress.emitProgress(
      tree,
      child.ply,
      child.fen,
      onProgress,
      config.maxPly,
      buildSw: _buildSw,
    );
  }

  // ── Prune eval-too-low (post-build cleanup) ────────────────────────────

  int _pruneEvalTooLow(BuildTree tree) {
    final removed = _pruneRecursive(tree, tree.root);
    if (removed > 0) {
      tree.totalNodes = tree.root.countSubtree();
    }
    return removed;
  }

  int _pruneRecursive(BuildTree tree, BuildTreeNode node) {
    int removed = 0;
    for (int i = node.children.length - 1; i >= 0; i--) {
      final child = node.children[i];
      if (child.pruneReason == PruneReason.evalTooLow) {
        final subtreeSize = child.countSubtree();
        _removeFromIndex(tree, child);
        node.children.removeAt(i);
        removed += subtreeSize;
      } else {
        removed += _pruneRecursive(tree, child);
      }
    }
    return removed;
  }

  void _removeFromIndex(BuildTree tree, BuildTreeNode node) {
    tree.nodeIndex.remove(node.nodeId);
    for (final child in node.children) {
      _removeFromIndex(tree, child);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  BuildTreeNode? _makeChild({
    required BuildTreeNode parent,
    required String fen,
    required String san,
    required String uci,
    required BuildTree tree,
  }) {
    // Dedup by FEN among siblings
    if (parent.children.any((c) => c.fen == fen)) return null;

    final whiteToMove = isWhiteToMove(fen);
    final child = BuildTreeNode(
      fen: fen,
      moveSan: san,
      moveUci: uci,
      ply: parent.ply + 1,
      isWhiteToMove: whiteToMove,
      nodeId: _nextNodeId++,
      parent: parent,
    );
    parent.children.add(child);
    tree.registerNode(child);
    tree.totalNodes++;
    child.extEvalMode = parent.extEvalMode;
    if (child.ply > tree.maxPlyReached) {
      tree.maxPlyReached = child.ply;
    }
    return child;
  }

  int _findMaxNodeId(BuildTreeNode node) {
    int maxId = node.nodeId;
    for (final child in node.children) {
      final childMax = _findMaxNodeId(child);
      if (childMax > maxId) maxId = childMax;
    }
    return maxId;
  }
}
