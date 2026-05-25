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
import '../utils/chess_utils.dart' show playUciMove, uciToSan;
import 'engine/stockfish_pool.dart';
import 'eval/cdbdirect_eval_provider.dart';
import 'eval/chessdb_api_provider.dart';
import 'eval/eval_chain.dart';
import 'eval/sqlite_eval_provider.dart';
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
  bool _isPaused = false;
  Completer<void>? _pauseCompleter;
  int _nextNodeId = 1;

  final EvalCache _evalCache = EvalCache.instance;
  final Map<String, ExplorerResponse?> _dbCache = {};

  SqliteEvalProvider? _localChessDb;
  CdbDirectEvalProvider? _cdbDirect;
  ChessDbApiProvider? _chessDbApi;

  late BuildStats _stats;
  Stopwatch _buildSw = Stopwatch();

  BuildStats get buildStats => _stats;
  ChessDbApiProvider? get chessDbApiProvider => _chessDbApi;

  int _lastProgressNodes = 0;

  /// True while Phase 1 BFS is running ([build] in progress).
  bool get isBuilding => _isBuilding;

  /// Phase 1 active-build elapsed time; stops advancing while [pauseBuild] holds.
  int get buildElapsedMs => _buildSw.elapsedMilliseconds;

  /// [BuildTree.totalNodes] when Phase 1 starts (after optional root eval).
  int _buildStartTotalNodes = 0;

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
    _buildSw = Stopwatch()..start();
    _lastProgressNodes = 0;
    _buildStartTotalNodes = 0;

    var cfg = config;
    _isPaused = false;
    _pauseCompleter = null;

    await Future.wait([
      if (cfg.usesStockfish)
        _pool.prepareForTreeBuild(cfg.resolvedEngineThreads)
      else
        Future.value(),
      _evalCache.init(),
    ]);
    await _initExternalEvalProviders(cfg);
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
      _dbCache.clear();
      _nextNodeId = 1;
      final rootFen = cfg.startFen;
      final isWhiteToMove = rootFen.split(' ')[1] == 'w';
      final root = BuildTreeNode(
        fen: rootFen,
        moveSan: '',
        moveUci: '',
        ply: 0,
        isWhiteToMove: isWhiteToMove,
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
      final gotEval = await _ensureEval(
        tree.root,
        cfg,
        fenMap: rootFenMap,
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

    _buildStartTotalNodes = tree.totalNodes;

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
      await _teardownExternalEvalProviders();
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
    // If paused, unblock the BFS loop so it can exit cleanly
    if (_isPaused) {
      _isPaused = false;
      _pauseCompleter?.complete();
      _pauseCompleter = null;
    }
  }

  // ── BFS build loop ─────────────────────────────────────────────────────

  Future<void> _buildBfsLoop({
    required BuildTree tree,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required bool Function() isCancelled,
    required void Function(BuildProgress) onProgress,
  }) async {
    final queue = Queue<BuildTreeNode>()..add(tree.root);
    while (_isBuilding && !isCancelled() && queue.isNotEmpty) {
      if (_isPaused && _pauseCompleter != null) {
        await _pauseCompleter!.future;
        if (!_isBuilding || isCancelled()) return;
      }
      final node = queue.removeFirst();
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

    if (node.ply >= config.maxPly) return;
    if (node.cumulativeProbability < config.minProbability) return;
    if (config.maxNodes > 0 && tree.totalNodes >= config.maxNodes) return;

    // Resume: skip nodes that already have children — enqueue them only
    if (node.children.isNotEmpty) {
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
      final gotEval = await _ensureEval(
        node,
        config,
        fenMap: fenMap,
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

    node.explored = true;

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
        ? (node.isWhiteToMove
            ? node.engineEvalCp!
            : -node.engineEvalCp!)
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
      final childEval = await _lookupDbEvalWhite(childFen, config);
      if (childEval == null) continue;

      final childIsWhite = childFen.split(' ')[1] == 'w';
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
      child.engineEvalCp =
          childIsWhite ? childCpWhite : -childCpWhite;
      _cacheEvalWhite(childFen, childCpWhite, childEval.$2);

      added++;
      _emitProgress(tree, child.ply, child.fen, onProgress, config.maxPly);
    }

    for (final child in List.of(node.children)) {
      if (!_isBuilding || isCancelled()) break;
      queue.add(child);
    }
  }

  /// DB-chain lookup returning white-normalized cp, or null on miss.
  Future<(int cp, int depth)?> _lookupDbEvalWhite(
    String fen,
    TreeBuildConfig config,
  ) async {
    final minDepth = config.effectiveMinEvalDepth;

    final cached = await _evalCache.getEvalCpWhite(fen, minDepth: minDepth);
    if (cached != null) {
      _stats.dbEvalHits++;
      return (cached, minDepth);
    }
    _stats.dbEvalMisses++;

    if (config.enableCdbDirect && _cdbDirect != null) {
      final cdb = await _cdbDirect!.lookup(fen, minDepth: minDepth);
      if (cdb.isHit) {
        _stats.cdbDirectHits++;
        final hit = cdb.hit!;
        final depth = hit.depth > 0 ? hit.depth : config.evalDepth;
        _cacheEvalWhite(fen, hit.cp, depth);
        return (hit.cp, depth);
      }
    }

    if (config.enableLocalChessDb && _localChessDb != null) {
      final local = await _localChessDb!.lookup(fen, minDepth: minDepth);
      if (local.isHit) {
        _stats.localChessDbHits++;
        final hit = local.hit!;
        final depth = hit.depth > 0 ? hit.depth : config.evalDepth;
        _cacheEvalWhite(fen, hit.cp, depth);
        return (hit.cp, depth);
      }
    }

    if (config.enableChessDbApi &&
        _chessDbApi != null &&
        _chessDbApi!.quotaRemaining) {
      final api = await _chessDbApi!.lookup(fen, minDepth: minDepth);
      if (api.isHit) {
        _stats.chessDbApiHits++;
        final hit = api.hit!;
        final depth = hit.depth > 0 ? hit.depth : config.evalDepth;
        _cacheEvalWhite(fen, hit.cp, depth);
        return (hit.cp, depth);
      }
    }

    return null;
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
      lichess = await _getDbData(node.fen, config);
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
          isWhiteToMove ? bestCp - line.effectiveCp : line.effectiveCp - bestCp;
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

      final childIsWhite = childFen.split(' ')[1] == 'w';
      final childEvalStm = isWhiteToMove ? -line.effectiveCp : line.effectiveCp;

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
      _cacheEvalWhite(childFen, childIsWhite ? childEvalStm : -childEvalStm,
          config.evalDepth);

      // Enrich with Lichess stats
      if (lichess != null) {
        final lm =
            lichess.moves.where((m) => m.uci == line.moveUci).firstOrNull;
        if (lm != null) {
          child.setLichessStats(lm.white, lm.black, lm.draws);
        }
      }

      _emitProgress(tree, child.ply, child.fen, onProgress, config.maxPly);
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
    final response = await _getDbData(node.fen, config);
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

      _emitProgress(tree, child.ply, child.fen, onProgress, config.maxPly);
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

      _emitProgress(tree, child.ply, child.fen, onProgress, config.maxPly);
    }
  }

  // ── Ensure eval (returns full result for bestmove reuse) ───────────────

  /// Ensure eval on [node]. Returns true when an eval was resolved.
  Future<bool> _ensureEval(
    BuildTreeNode node,
    TreeBuildConfig config, {
    required FenMap fenMap,
    bool dbOnly = false,
  }) async {
    if (node.hasEngineEval) return true;

    final outcome = await resolveEvalChain(
      fen: node.fen,
      config: config,
      cache: _evalCache,
      stats: _stats,
      localChessDb: _localChessDb,
      cdbDirect: _cdbDirect,
      chessDbApi: _chessDbApi,
      extEvalMode: node.extEvalMode,
      canonicalNode: fenMap.getCanonical(node.fen),
      allowStockfishFallback: !dbOnly,
      stockfishEval: (f, depth) async {
        final sw = Stopwatch()..start();
        final result = await _pool.evaluateFen(f, depth);
        _stats.sfSingleMs += sw.elapsedMilliseconds;
        return (stmCp: result.effectiveCp, depth: depth);
      },
      cacheWrite: (f, whiteCp, depth) async {
        _cacheEvalWhite(f, whiteCp, depth);
      },
    );

    if (outcome.extEvalMode != node.extEvalMode) {
      node.extEvalMode = outcome.extEvalMode;
    }

    if (outcome.whiteCp != null) {
      final isWhiteStm = node.fen.split(' ')[1] == 'w';
      node.engineEvalCp =
          isWhiteStm ? outcome.whiteCp! : -outcome.whiteCp!;
      return true;
    }
    return false;
  }

  Future<void> _initExternalEvalProviders(TreeBuildConfig config) async {
    await _teardownExternalEvalProviders();

    await CdbDirectEvalProvider.probeAvailability();
    if (config.enableCdbDirect &&
        config.cdbDirectPath.isNotEmpty &&
        CdbDirectEvalProvider.isAvailable) {
      final provider = CdbDirectEvalProvider(path: config.cdbDirectPath);
      if (await provider.init()) {
        _cdbDirect = provider;
      }
    }

    if (config.enableLocalChessDb && config.localChessDbPath.isNotEmpty) {
      final provider = SqliteEvalProvider(path: config.localChessDbPath);
      if (await provider.init()) {
        _localChessDb = provider;
      }
    }

    if (config.enableChessDbApi) {
      _chessDbApi = ChessDbApiProvider(
        dailyQuota: config.chessDbApiDailyQuota,
        concurrency: config.chessDbApiConcurrency,
      );
      await _chessDbApi!.init();
    }
  }

  Future<void> _teardownExternalEvalProviders() async {
    await _localChessDb?.close();
    _localChessDb = null;
    await _cdbDirect?.close();
    _cdbDirect = null;
    if (_chessDbApi != null) {
      await _chessDbApi!.flushQuota();
      _chessDbApi = null;
    }
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

    final isWhiteToMove = fen.split(' ')[1] == 'w';
    final child = BuildTreeNode(
      fen: fen,
      moveSan: san,
      moveUci: uci,
      ply: parent.ply + 1,
      isWhiteToMove: isWhiteToMove,
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

  Future<ExplorerResponse?> _getDbData(
    String fen,
    TreeBuildConfig config,
  ) async {
    final cacheKey = '${config.useMasters ? "m" : "l"}|$fen';
    if (_dbCache.containsKey(cacheKey)) {
      _stats.dbExplorerHits++;
      return _dbCache[cacheKey];
    }
    _stats.dbExplorerMisses++;
    _stats.lichessQueries++;
    final data = await _probabilityService.getProbabilitiesForFen(
      fen,
      speeds: config.speeds,
      ratings: config.ratingRange,
      useMasters: config.useMasters,
    );
    _dbCache[cacheKey] = data;
    return data;
  }

  /// Persist an eval (white-normalized cp).  Fire-and-forget — the L1
  /// mirror inside [EvalCache] is updated synchronously, so subsequent
  /// reads hit immediately without awaiting the DB write.
  void _cacheEvalWhite(String fen, int whiteCp, int depth) {
    unawaited(_evalCache.putEvalCpWhite(fen, whiteCp, depth));
  }

  void _emitProgress(
    BuildTree tree,
    int ply,
    String? fen,
    void Function(BuildProgress) onProgress,
    int maxPlyConfig,
  ) {
    if (tree.totalNodes - _lastProgressNodes < 5 && tree.totalNodes > 2) {
      return;
    }
    _lastProgressNodes = tree.totalNodes;

    final elapsedMs = _buildSw.elapsedMilliseconds;
    final d = tree.maxPlyReached;

    int totalAtDepth = 0;
    int unexploredAtDepth = 0;
    _countDepthLayer(tree.root, d, (total, unexplored) {
      totalAtDepth = total;
      unexploredAtDepth = unexplored;
    });

    double? nodesPerMinute;
    int? etaDepthSeconds;

    final elapsedMin = elapsedMs / 60000.0;
    final deltaNodes = tree.totalNodes - _buildStartTotalNodes;
    if (elapsedMs >= 500 && elapsedMin > 0 && deltaNodes >= 1) {
      nodesPerMinute = deltaNodes / elapsedMin;
      if (nodesPerMinute > 0 && unexploredAtDepth > 0) {
        etaDepthSeconds = (unexploredAtDepth * 60.0 / nodesPerMinute)
            .round()
            .clamp(1, 86400 * 7);
      }
    }

    onProgress(BuildProgress(
      totalNodes: tree.totalNodes,
      maxPlyReached: d,
      maxPlyConfig: maxPlyConfig,
      elapsedMs: elapsedMs,
      nodesPerMinute: nodesPerMinute,
      currentDepth: d,
      unexploredAtDepth: unexploredAtDepth,
      totalAtDepth: totalAtDepth,
      etaDepthSeconds: etaDepthSeconds,
    ));
  }

  static void _countDepthLayer(
    BuildTreeNode node,
    int targetPly,
    void Function(int total, int unexplored) callback,
  ) {
    int total = 0;
    int unexplored = 0;
    _walkDepthLayer(node, targetPly, (n) {
      total++;
      if (!n.explored) unexplored++;
    });
    callback(total, unexplored);
  }

  static void _walkDepthLayer(
    BuildTreeNode node,
    int targetPly,
    void Function(BuildTreeNode) visitor,
  ) {
    if (node.ply == targetPly) {
      visitor(node);
      return;
    }
    for (final c in node.children) {
      _walkDepthLayer(c, targetPly, visitor);
    }
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
