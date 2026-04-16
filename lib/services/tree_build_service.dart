/// Two-phase tree builder — builds a persistent [BuildTree] with engine
/// evaluations on every node, matching the C tree_builder algorithm.
///
/// Phase 1 (this service): DFS build with constant-depth MultiPV at
/// our-move nodes, single-source opponent moves (Maia OR Lichess), eval-
/// window pruning, and transposition detection.
///
/// Phase 2 (separate calculators): ease, expectimax, and repertoire
/// selection run on the completed tree.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/build_tree_node.dart';
import '../utils/chess_utils.dart' show playUciMove, uciToSan;
import 'engine/stockfish_pool.dart';
import 'eval_cache.dart';
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

  final EvalCache _evalCache = EvalCache.instance;
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

    await Future.wait([
      _pool.ensureWorkers(),
      _evalCache.init(),
    ]);
    if (_pool.workerCount == 0) {
      throw StateError('No engine workers available');
    }

    BuildTree tree;
    if (existingTree != null) {
      tree = existingTree;
      _nextNodeId = _findMaxNodeId(tree.root) + 1;
    } else {
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
          ourMultipv: cfg.ourMultipv,
          maxEvalLossCp: cfg.maxEvalLossCp,
          oppMaxChildren: cfg.oppMaxChildren,
          oppMassTarget: cfg.oppMassTarget,
          minEvalCp: cfg.minEvalCp + rootEvalUs,
          maxEvalCp: cfg.maxEvalCp + rootEvalUs,
          relativeEval: cfg.relativeEval,
          useLichessDb: cfg.useLichessDb, useMasters: cfg.useMasters,
          ratingRange: cfg.ratingRange,
          speeds: cfg.speeds, minGames: cfg.minGames,
          maiaElo: cfg.maiaElo, maiaMinProb: cfg.maiaMinProb,
          maiaOnly: cfg.maiaOnly,
          leafConfidence: cfg.leafConfidence,
          noveltyWeight: cfg.noveltyWeight,
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

    final isOurMove = node.isWhiteToMove == config.playAsWhite;

    // Opponent-move nodes: ensure eval + window prune BEFORE expansion.
    // Our-move nodes skip this — their eval comes from MultiPV line 0
    // inside _buildOurMove, which also does its own window check.
    // This matches C's build_recursive where ensure_eval + window is
    // gated on `!is_our_move`.
    if (!isOurMove) {
      await _ensureEval(node, config);
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
    final mpvCount = config.ourMultipv;
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
      _cacheEvalWhite(node.fen, topCp, config.evalDepth);
    }

    // Eval-window pruning (deferred from _buildRecursive so the eval
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
          childIsWhite ? childEvalStm : -childEvalStm,
          config.evalDepth);

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

    // Populate maia_frequency on our-move children.  C gates this on
    // `populate_maia_frequency` (novelty > 0 || find_traps); Dart always
    // populates when Maia is available since the data is useful for both
    // novelty scoring and trap-line display.
    if (MaiaFactory.isAvailable &&
        MaiaFactory.instance != null &&
        node.children.isNotEmpty) {
      try {
        final maiaResult = await MaiaFactory.instance!.evaluate(
          node.fen, config.maiaElo,
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

    // Recurse into children
    for (final child in List.of(node.children)) {
      if (!_isBuilding || isCancelled()) break;
      await _buildRecursive(
        tree: tree, node: child, config: config,
        fenMap: fenMap, isCancelled: isCancelled, onProgress: onProgress,
      );
    }
  }

  // ── Opponent move: single source (Maia OR Lichess) → recurse ─────────

  Future<void> _buildOpponentMove({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
  }) async {
    if (config.maiaOnly) {
      await _addOpponentChildrenFromMaia(
        tree: tree, node: node, config: config, onProgress: onProgress,
      );
    } else {
      await _addOpponentChildrenFromLichess(
        tree: tree, node: node, config: config, onProgress: onProgress,
      );
    }

    if (node.children.isEmpty) return;

    // Probabilities are kept RAW (Σ pᵢ ≤ 1).  The expectimax tail term
    // accounts for uncovered mass; renormalizing would silently bias V.

    // Recurse — eval-window check + ensureEval happen inside _buildRecursive,
    // so no separate batch-eval pass is needed here.
    for (final child in List.of(node.children)) {
      if (!_isBuilding || isCancelled()) break;
      await _buildRecursive(
        tree: tree, node: child, config: config,
        fenMap: fenMap, isCancelled: isCancelled, onProgress: onProgress,
      );
    }
  }

  Future<void> _addOpponentChildrenFromLichess({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required void Function(BuildProgress) onProgress,
  }) async {
    final response = await _getDbData(node.fen);
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

  Future<void> _addOpponentChildrenFromMaia({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required void Function(BuildProgress) onProgress,
  }) async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) return;

    final sw = Stopwatch()..start();
    final MaiaResult maiaResult;
    try {
      maiaResult = await MaiaFactory.instance!.evaluate(
        node.fen, config.maiaElo,
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

    int childrenAdded = 0;
    double massCovered = 0.0;
    final massTarget = config.oppMassTarget;

    for (final entry in sortedMoves) {
      final uci = entry.key;
      final prob = entry.value;
      if (prob < config.maiaMinProb) continue;
      if (config.oppMaxChildren > 0 &&
          childrenAdded >= config.oppMaxChildren) {
        break;
      }
      if (massTarget > 0.0 && massCovered >= massTarget) break;

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

  // ── Ensure eval (returns full result for bestmove reuse) ───────────────

  Future<void> _ensureEval(
      BuildTreeNode node, TreeBuildConfig config) async {
    if (node.hasEngineEval) return;

    final cached = await _getCachedEvalWhite(node.fen, config.evalDepth);
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
        isWhiteStm ? result.effectiveCp : -result.effectiveCp,
        config.evalDepth);
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

  /// Persist an eval (white-normalized cp).  Fire-and-forget — the L1
  /// mirror inside [EvalCache] is updated synchronously, so subsequent
  /// reads hit immediately without awaiting the DB write.
  void _cacheEvalWhite(String fen, int whiteCp, int depth) {
    unawaited(_evalCache.putEvalCpWhite(fen, whiteCp, depth));
  }

  Future<int?> _getCachedEvalWhite(String fen, int minDepth) =>
      _evalCache.getEvalCpWhite(fen, minDepth: minDepth);

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
