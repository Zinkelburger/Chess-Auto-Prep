/// Two-phase tree builder — builds a persistent [BuildTree] with engine
/// evaluations on every node, matching the C tree_builder algorithm.
///
/// Phase 1 (this service): DFS build with MultiPV tapering (our moves),
/// Lichess+Maia blended opponent moves, eval-window pruning, and
/// transposition detection.
///
/// Phase 2 (separate calculators): ease, ECA, and repertoire selection
/// run on the completed tree.
library;

import 'package:flutter/foundation.dart';

import '../models/build_tree_node.dart';
import '../utils/chess_utils.dart' show playUciMove, uciToSan;
import 'engine/stockfish_pool.dart';
import 'generation/fen_map.dart';
import 'generation/generation_config.dart';
import 'maia_factory.dart';
import 'maia_service.dart';
import 'probability_service.dart';

class TreeBuildService {
  final StockfishPool _pool = StockfishPool();
  final ProbabilityService _probabilityService = ProbabilityService();

  bool _isBuilding = false;
  int _nextNodeId = 1;

  final Map<String, int> _evalCache = {};
  final Map<String, ExplorerResponse?> _dbCache = {};

  late BuildStats _stats;
  late Stopwatch _buildSw;

  int _lastProgressNodes = 0;

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
    _buildSw = Stopwatch()..start();
    _lastProgressNodes = 0;

    var cfg = config;

    await _pool.ensureWorkers();
    if (_pool.workerCount == 0) {
      throw StateError('No engine workers available');
    }

    BuildTree tree;
    if (existingTree != null) {
      tree = existingTree;
      _nextNodeId = _findMaxNodeId(tree.root) + 1;
    } else {
      _evalCache.clear();
      _dbCache.clear();
      _nextNodeId = 1;
      final rootFen = cfg.startFen;
      final isWhiteToMove = rootFen.split(' ')[1] == 'w';
      final root = BuildTreeNode(
        fen: rootFen,
        moveSan: '',
        moveUci: '',
        depth: 0,
        isWhiteToMove: isWhiteToMove,
        nodeId: _nextNodeId++,
      );
      tree = BuildTree(
        root: root,
        configSnapshot: cfg.toJson(),
      );
    }

    _isBuilding = true;

    if (cfg.relativeEval) {
      await _ensureEval(tree.root, cfg);
      if (tree.root.hasEngineEval) {
        final rootEvalUs = tree.root.evalForUs(cfg.playAsWhite);
        cfg = TreeBuildConfig(
          startFen: cfg.startFen, playAsWhite: cfg.playAsWhite,
          minProbability: cfg.minProbability, maxDepth: cfg.maxDepth,
          maxNodes: cfg.maxNodes, evalDepth: cfg.evalDepth,
          ourMultipvRoot: cfg.ourMultipvRoot,
          ourMultipvFloor: cfg.ourMultipvFloor,
          taperDepth: cfg.taperDepth, maxEvalLossCp: cfg.maxEvalLossCp,
          oppMaxChildren: cfg.oppMaxChildren, oppMassRoot: cfg.oppMassRoot,
          oppMassFloor: cfg.oppMassFloor,
          minEvalCp: cfg.minEvalCp + rootEvalUs,
          maxEvalCp: cfg.maxEvalCp + rootEvalUs,
          relativeEval: cfg.relativeEval,
          useLichessDb: cfg.useLichessDb, ratingRange: cfg.ratingRange,
          speeds: cfg.speeds, minGames: cfg.minGames,
          maiaElo: cfg.maiaElo, maiaThreshold: cfg.maiaThreshold,
          maiaMinProb: cfg.maiaMinProb,
          depthDiscount: cfg.depthDiscount, trickWeight: cfg.trickWeight,
          leafConfidence: cfg.leafConfidence,
        );
      }
    }

    final fenMap = FenMap();

    try {
      await _buildRecursive(
        tree: tree,
        node: tree.root,
        config: cfg,
        fenMap: fenMap,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
    } finally {
      fenMap.clear();
    }

    final pruned = _pruneEvalTooLow(tree);
    if (pruned > 0) {
      _log('Pruned $pruned eval-too-low nodes');
    }

    tree.buildComplete = _isBuilding;
    _isBuilding = false;
    _buildSw.stop();

    _log('Build complete: ${tree.totalNodes} nodes, '
        'depth ${tree.maxDepthReached}, '
        '${_buildSw.elapsedMilliseconds}ms');

    return tree;
  }

  void stopBuild() {
    _isBuilding = false;
  }

  // ── Core DFS ───────────────────────────────────────────────────────────

  Future<void> _buildRecursive({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
  }) async {
    if (!_isBuilding || isCancelled()) return;
    if (node.depth >= config.maxDepth) return;
    if (node.cumulativeProbability < config.minProbability) return;
    if (config.maxNodes > 0 && tree.totalNodes >= config.maxNodes) return;

    // Resume: skip nodes that already have children
    if (node.children.isNotEmpty) {
      fenMap.putCanonical(node.fen, node);
      for (final child in node.children) {
        await _buildRecursive(
          tree: tree, node: child, config: config,
          fenMap: fenMap, isCancelled: isCancelled, onProgress: onProgress,
        );
      }
      return;
    }
    if (node.explored) return;

    await _ensureEval(node, config);

    // Eval-window pruning
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

    // Transposition detection
    final canonical = fenMap.getCanonical(node.fen);
    if (canonical != null) {
      fenMap.addTransposition(node.fen, node);
      node.explored = true;
      return;
    }
    fenMap.putCanonical(node.fen, node);

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    node.explored = true;

    if (isOurMove) {
      await _buildOurMove(
        tree: tree, node: node, config: config, fenMap: fenMap,
        isCancelled: isCancelled, onProgress: onProgress,
      );
    } else {
      await _buildOpponentMove(
        tree: tree, node: node, config: config, fenMap: fenMap,
        isCancelled: isCancelled, onProgress: onProgress,
      );
    }
  }

  // ── Our move: Stockfish MultiPV → eval filter → recurse ───────────────

  Future<void> _buildOurMove({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
  }) async {
    final mpvCount = config.multipvForDepth(node.depth);
    final isWhiteToMove = node.fen.split(' ')[1] == 'w';

    final sw = Stopwatch()..start();
    final discovery = await _pool.discoverMoves(
      fen: node.fen,
      depth: config.evalDepth,
      multiPv: mpvCount,
      isWhiteToMove: isWhiteToMove,
    );
    _stats.sfMultipvCalls++;
    _stats.sfMultipvMs += sw.elapsedMilliseconds;

    if (discovery.lines.isEmpty) return;

    // Set node eval from top line
    if (!node.hasEngineEval) {
      final topCp = discovery.lines.first.effectiveCp;
      final stmCp = isWhiteToMove ? topCp : -topCp;
      node.engineEvalCp = stmCp;
      _cacheEvalWhite(node.fen, topCp);
    }

    // Optional Lichess enrichment for SAN + win rates
    ExplorerResponse? lichess;
    if (config.useLichessDb) {
      lichess = await _getDbData(node.fen);
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
      final evalLoss = isWhiteToMove
          ? bestCp - line.effectiveCp
          : line.effectiveCp - bestCp;
      if (evalLoss > config.maxEvalLossCp) continue;

      final childFen = playUciMove(node.fen, line.moveUci);
      if (childFen == null) continue;

      // Dedup by FEN (catches castling representation mismatches)
      if (node.children.any((c) => c.fen == childFen)) continue;

      // Get SAN from Lichess data or compute it
      String san = line.moveUci;
      if (lichess != null) {
        final lichessMove = lichess.moves
            .where((m) => m.uci == line.moveUci)
            .firstOrNull;
        if (lichessMove != null) {
          san = lichessMove.san;
        }
      }
      if (san == line.moveUci) {
        san = uciToSan(node.fen, line.moveUci);
      }

      final childIsWhite = childFen.split(' ')[1] == 'w';
      final childEvalStm = isWhiteToMove ? -line.effectiveCp : line.effectiveCp;

      final child = _makeChild(
        parent: node, fen: childFen, san: san, uci: line.moveUci, tree: tree,
      );
      if (child == null) continue;

      child.moveProbability = 1.0;
      child.cumulativeProbability = node.cumulativeProbability;
      child.engineEvalCp = childEvalStm;
      _cacheEvalWhite(childFen,
          childIsWhite ? childEvalStm : -childEvalStm);

      // Enrich with Lichess stats
      if (lichess != null) {
        final lm = lichess.moves
            .where((m) => m.uci == line.moveUci)
            .firstOrNull;
        if (lm != null) {
          child.setLichessStats(lm.white, lm.black, lm.draws);
        }
      }

      _emitProgress(tree, child.depth, child.fen, onProgress);
    }

    // Recurse into children
    for (final child in List.of(node.children)) {
      if (!_isBuilding || isCancelled()) break;
      await _buildRecursive(
        tree: tree, node: child, config: config,
        fenMap: fenMap, isCancelled: isCancelled, onProgress: onProgress,
      );
    }
  }

  // ── Opponent move: Lichess + Maia → recurse ─────────────────────────

  Future<void> _buildOpponentMove({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
  }) async {
    final massTarget = config.oppMassForDepth(node.depth);
    int childrenAdded = 0;
    double massCovered = 0.0;

    MaiaResult? maiaResult;

    // ── 1. Lichess moves ──
    if (config.useLichessDb) {
      final response = await _getDbData(node.fen);
      if (response != null && response.totalGames > 0) {
        final totalW = response.moves.fold(0, (s, m) => s + m.white);
        final totalB = response.moves.fold(0, (s, m) => s + m.black);
        final totalD = response.moves.fold(0, (s, m) => s + m.draws);
        node.setLichessStats(totalW, totalB, totalD);

        for (final move in response.moves) {
          if (move.total < config.minGames) continue;
          if (config.oppMaxChildren > 0 &&
              childrenAdded >= config.oppMaxChildren) {
            break;
          }
          if (massTarget > 0.0 && massCovered >= massTarget) break;

          final prob = move.playFraction;
          final newCumul = node.cumulativeProbability * prob;
          if (newCumul < config.minProbability) continue;

          final childFen = playUciMove(node.fen, move.uci);
          if (childFen == null) continue;

          final child = _makeChild(
            parent: node, fen: childFen, san: move.san,
            uci: move.uci, tree: tree,
          );
          if (child == null) continue;

          child.moveProbability = prob;
          child.cumulativeProbability = newCumul;
          child.setLichessStats(move.white, move.black, move.draws);
          childrenAdded++;
          massCovered += prob;

          _emitProgress(tree, child.depth, child.fen, onProgress);
        }
      }
    }

    // ── 2. Maia supplement ──
    final needMaia = !config.useLichessDb ||
        (massCovered < massTarget &&
            (config.oppMaxChildren <= 0 ||
                childrenAdded < config.oppMaxChildren));

    if (needMaia &&
        MaiaFactory.isAvailable &&
        MaiaFactory.instance != null &&
        (!config.useLichessDb ||
            node.cumulativeProbability >= config.maiaThreshold)) {
      final sw = Stopwatch()..start();
      try {
        maiaResult = await MaiaFactory.instance!.evaluate(
          node.fen, config.maiaElo,
        );
        _stats.maiaEvals++;
        _stats.maiaTotalMs += sw.elapsedMilliseconds;

        if (maiaResult.policy.isNotEmpty) {
          final sortedMoves = maiaResult.policy.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));

          for (final entry in sortedMoves) {
            final uci = entry.key;
            final prob = entry.value;
            if (prob < config.maiaMinProb) continue;
            if (config.oppMaxChildren > 0 &&
                childrenAdded >= config.oppMaxChildren) {
              break;
            }
            if (massTarget > 0.0 && massCovered >= massTarget) break;

            // Skip if already added from Lichess
            if (node.children.any((c) => c.moveUci == uci)) continue;

            final newCumul = node.cumulativeProbability * prob;
            if (newCumul < config.minProbability) continue;

            final childFen = playUciMove(node.fen, uci);
            if (childFen == null) continue;

            final san = uciToSan(node.fen, uci);
            final child = _makeChild(
              parent: node, fen: childFen, san: san, uci: uci, tree: tree,
            );
            if (child == null) continue;

            child.moveProbability = prob;
            child.cumulativeProbability = newCumul;
            childrenAdded++;
            massCovered += prob;

            _emitProgress(tree, child.depth, child.fen, onProgress);
          }
        }
      } catch (e) {
        _log('Maia eval failed: $e');
      }
    }

    if (childrenAdded == 0 && node.children.isEmpty) return;

    // ── 3. Probability normalization ──
    _normalizeChildProbabilities(node);

    // ── 4. Batch eval children without evals ──
    final needEval = <int>[];
    final needEvalFens = <String>[];
    for (int i = 0; i < node.children.length; i++) {
      if (!node.children[i].hasEngineEval) {
        final cached = _getCachedEvalWhite(node.children[i].fen);
        if (cached != null) {
          final isChildWhiteStm = node.children[i].fen.split(' ')[1] == 'w';
          node.children[i].engineEvalCp =
              isChildWhiteStm ? cached : -cached;
        } else {
          needEval.add(i);
          needEvalFens.add(node.children[i].fen);
        }
      }
    }
    if (needEvalFens.isNotEmpty) {
      final sw = Stopwatch()..start();
      final results = await _pool.evaluateMany(needEvalFens, config.evalDepth);
      _stats.sfBatchCalls++;
      _stats.sfBatchMs += sw.elapsedMilliseconds;
      for (int k = 0; k < needEval.length; k++) {
        final child = node.children[needEval[k]];
        child.engineEvalCp = results[k].effectiveCp;
        final isChildWhiteStm = child.fen.split(' ')[1] == 'w';
        _cacheEvalWhite(child.fen,
            isChildWhiteStm
                ? results[k].effectiveCp
                : -results[k].effectiveCp);
      }
    }

    // ── 5. Recurse ──
    for (final child in List.of(node.children)) {
      if (!_isBuilding || isCancelled()) break;
      await _buildRecursive(
        tree: tree, node: child, config: config,
        fenMap: fenMap, isCancelled: isCancelled, onProgress: onProgress,
      );
    }
  }

  // ── Ensure eval (returns full result for bestmove reuse) ───────────────

  Future<void> _ensureEval(
      BuildTreeNode node, TreeBuildConfig config) async {
    if (node.hasEngineEval) return;

    // Check cache
    final cached = _getCachedEvalWhite(node.fen);
    if (cached != null) {
      final isWhiteStm = node.fen.split(' ')[1] == 'w';
      node.engineEvalCp = isWhiteStm ? cached : -cached;
      _stats.dbEvalHits++;
      return;
    }
    _stats.dbEvalMisses++;

    final sw = Stopwatch()..start();
    final result = await _pool.evaluateFen(node.fen, config.evalDepth);
    _stats.sfSingleCalls++;
    _stats.sfSingleMs += sw.elapsedMilliseconds;

    node.engineEvalCp = result.effectiveCp;
    final isWhiteStm = node.fen.split(' ')[1] == 'w';
    _cacheEvalWhite(node.fen,
        isWhiteStm ? result.effectiveCp : -result.effectiveCp);
  }

  // ── Prune eval-too-low (post-build cleanup) ────────────────────────────

  int _pruneEvalTooLow(BuildTree tree) {
    final removed = _pruneRecursive(tree.root);
    if (removed > 0) {
      tree.totalNodes = tree.root.countSubtree();
    }
    return removed;
  }

  int _pruneRecursive(BuildTreeNode node) {
    int removed = 0;
    for (int i = node.children.length - 1; i >= 0; i--) {
      final child = node.children[i];
      if (child.pruneReason == PruneReason.evalTooLow) {
        final subtreeSize = child.countSubtree();
        node.children.removeAt(i);
        removed += subtreeSize;
      } else {
        removed += _pruneRecursive(child);
      }
    }
    return removed;
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

    final isWhiteToMove = fen.split(' ')[1] == 'w';
    final child = BuildTreeNode(
      fen: fen,
      moveSan: san,
      moveUci: uci,
      depth: parent.depth + 1,
      isWhiteToMove: isWhiteToMove,
      nodeId: _nextNodeId++,
      parent: parent,
    );
    parent.children.add(child);
    tree.totalNodes++;
    if (child.depth > tree.maxDepthReached) {
      tree.maxDepthReached = child.depth;
    }
    return child;
  }

  void _normalizeChildProbabilities(BuildTreeNode node) {
    if (node.children.isEmpty) return;
    double probSum = 0.0;
    for (final child in node.children) {
      probSum += child.moveProbability;
    }
    if (probSum <= 0.0 || (probSum - 1.0).abs() < 1e-9) return;
    for (final child in node.children) {
      child.moveProbability /= probSum;
      child.cumulativeProbability =
          node.cumulativeProbability * child.moveProbability;
    }
  }

  Future<ExplorerResponse?> _getDbData(String fen) async {
    if (_dbCache.containsKey(fen)) {
      _stats.dbExplorerHits++;
      return _dbCache[fen];
    }
    _stats.dbExplorerMisses++;
    _stats.lichessQueries++;
    final data = await _probabilityService.getProbabilitiesForFen(fen);
    _dbCache[fen] = data;
    return data;
  }

  void _cacheEvalWhite(String fen, int whiteCp) {
    _evalCache[fen] = whiteCp;
  }

  int? _getCachedEvalWhite(String fen) => _evalCache[fen];

  void _emitProgress(
    BuildTree tree, int depth, String? fen,
    void Function(BuildProgress) onProgress,
  ) {
    if (tree.totalNodes - _lastProgressNodes < 5 &&
        tree.totalNodes > 2) {
      return;
    }
    _lastProgressNodes = tree.totalNodes;
    onProgress(BuildProgress(
      totalNodes: tree.totalNodes,
      currentDepth: depth,
      maxDepthReached: tree.maxDepthReached,
      currentFen: fen,
      elapsedMs: _buildSw.elapsedMilliseconds,
      engineCalls: _stats.sfMultipvCalls +
          _stats.sfSingleCalls + _stats.sfBatchCalls,
      engineCacheHits: _stats.dbEvalHits,
      maiaCalls: _stats.maiaEvals,
      lichessQueries: _stats.lichessQueries,
      lichessCacheHits: _stats.lichessCacheHits,
      message: '${tree.totalNodes}n d=$depth '
          'eng=${_stats.sfMultipvCalls + _stats.sfSingleCalls + _stats.sfBatchCalls} '
          'maia=${_stats.maiaEvals}',
    ));
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
