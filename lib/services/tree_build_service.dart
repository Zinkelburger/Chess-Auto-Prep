/// Two-phase tree builder — builds a persistent [BuildTree] with engine
/// evaluations on every node, matching the C tree_builder algorithm.
///
/// Phase 1 (this service): frontier-driven build with constant MultiPV at
/// our-move nodes, single-source opponent moves (Maia OR Lichess with an
/// optional Maia Dirichlet prior), eval-window pruning, and transposition
/// detection — matches C tree_builder.
///
/// Frontier discipline (config.bestFirst):
///   - Best-first (default): pop the frontier node with the highest search
///     priority — reach probability, discounted at non-incumbent our-move
///     alternatives.  Anytime: at any node budget the tree concentrates on
///     the likeliest opponent lines, which also get searched deepest.
///   - FIFO: classic level-order BFS (legacy behavior).
///
/// Phase 2 (separate calculators): ease, expectimax, and repertoire
/// selection run on the completed tree.  Search priorities never feed
/// phase 2 — they shape which nodes exist, not how they are valued.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/build_tree_node.dart';
import '../models/explorer_response.dart';
import '../utils/chess_utils.dart' show playUciMove, sanToUci, uciToSan;
import '../utils/fen_utils.dart';
import 'engine/stockfish_pool.dart';
import 'engine/engine_lifecycle.dart';
import 'eval/chessdb_api_provider.dart';
import 'generation/fen_map.dart';
import 'generation/frontier_queue.dart';
import 'generation/generation_config.dart';
import 'generation/opponent_prior.dart';
import 'generation/setup_bias.dart';
import 'generation/pgn_freq_map.dart';
import 'generation/tree_build_progress.dart';
import 'generation/tree_eval_resolver.dart';
import 'generation/tree_prune.dart';
import 'maia_factory.dart';
import 'maia_service.dart';

class TreeBuildService {
  final StockfishPool _pool = StockfishPool.instance;
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
          EngineLifecycle.instance.state != EngineState.generating)
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
      // Skipped on hard cancel (_isBuilding false): the tree stays resumable
      // and the sweep would only throw away resumable frontier leaves.
      if (_isBuilding) {
        await _coverageSweep(
          tree: tree,
          config: cfg,
          fenMap: fenMap,
          onProgress: onProgress,
        );
      }
    } finally {
      fenMap.clear();
      await _evalResolver.teardownProviders();
    }

    final pruned = pruneEvalTooLow(tree);
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
    String? startMoves,
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
    final hasStartMoves = startMoves != null && startMoves.isNotEmpty;
    final pgnCustomFen =
        !_fenKeysEqual(config.startFen, kDefaultStartFen);
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
        '${freqStats.parseErrors} movetext errors, '
        '${freqStats.fileReadErrors} file read errors');

    if (freqStats.totalGames == 0) {
      _buildSw.stop();
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
    root.searchPriority = 1.0;

    final fenMap = FenMap();
    final queue = FrontierQueue(bestFirst: config.bestFirst);
    queue.add(root);

    while (_isBuilding && !isCancelled() && queue.isNotEmpty) {
      if (_isPaused && _pauseCompleter != null) {
        await _pauseCompleter!.future;
        if (!_isBuilding || isCancelled()) break;
      }

      final node = queue.removeFirst();
      if (node.explored) continue;

      await _processDbExplorerNode(
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
        if (EngineLifecycle.instance.state != EngineState.generating) {
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
        // After enrichment the engine is available, so holes where the
        // user's games ran out can get an engine answer.
        if (_isBuilding) {
          await _coverageSweep(
            tree: tree,
            config: config,
            fenMap: fenMap,
            onProgress: onProgress,
          );
        }
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

  Future<void> _processDbExplorerNode({
    required BuildTree tree,
    required BuildTreeNode node,
    required PgnFreqMap freqMap,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required FrontierQueue queue,
    required void Function(BuildProgress) onProgress,
  }) async {
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
      if (node.cumulativeProbability > canonical.cumulativeProbability) {
        propagateHigherCumP(
          canonical,
          node.cumulativeProbability,
          config.minProbability,
          queue,
        );
      }
      node.explored = true;
      return;
    }
    fenMap.putCanonical(node.fen, node);

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

      final maiaPolicy = await _maiaPolicyForSmoothing(node.fen, reach, config);
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

      for (final m in candidates) {
        final prob = m.probability;
        final newCumul = node.cumulativeProbability * prob;
        // Coverage floor: see _addOpponentChildrenFromLichess.
        final covered =
            config.coverMinProb > 0.0 && prob >= config.coverMinProb;
        if (!covered) {
          if (config.maxNodes > 0 && tree.totalNodes >= config.maxNodes) {
            break;
          }
          // The prior replaces the min-games noise filter when smoothing.
          if (!smoothing && m.games < config.dbMinGames) continue;
          if (m.probability < config.dbMinProb) continue;
          if (newCumul < config.minProbability) continue;
        }

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
        child.searchPriority = basePri * prob;
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
      _progress.initForResume(minFrontierPly: minPly);
    } else {
      tree.root.searchPriority = 1.0;
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
    required FrontierQueue queue,
  }) async {
    if (!_isBuilding || isCancelled()) return;

    // Pause gate: if paused, wait until resumed or cancelled
    if (_isPaused && _pauseCompleter != null) {
      await _pauseCompleter!.future;
      if (!_isBuilding || isCancelled()) return;
    }

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
            fenMap: fenMap,
            pool: _pool,
          );
        }
        node.explored = true;
        return;
      }
      coverageOnly = true;
    }
    // Discounted our-move alternatives whose priority fell below the floor
    // are not worth budget (searchPriority ≤ cumulativeProbability always).
    final belowFloor = node.cumulativeProbability < config.minProbability ||
        (config.bestFirst &&
            node.searchPriority >= 0.0 &&
            node.searchPriority < config.minProbability);
    if (belowFloor && !coverageOnly) {
      if (!owesAnswer) return;
      coverageOnly = true;
    }
    if (config.maxNodes > 0 && tree.totalNodes >= config.maxNodes) {
      if (!owesAnswer) return;
      coverageOnly = true;
    }

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
      if (node.cumulativeProbability > canonical.cumulativeProbability) {
        propagateHigherCumP(
          canonical,
          node.cumulativeProbability,
          config.minProbability,
          queue,
        );
      }
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
          coverageOnly: coverageOnly,
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
          coverageOnly: coverageOnly,
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
    required FrontierQueue queue,
    bool coverageOnly = false,
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

    await _injectSetupCandidates(
      tree: tree,
      node: node,
      config: config,
      bestCpWhite: bestCpWhite,
      onProgress: onProgress,
    );

    _assignOurMovePriorities(node, config);

    // Coverage-only: the answer is the deliverable — children stay
    // unexplored leaves so a future resume with more budget can deepen them.
    if (coverageOnly) return;

    for (final child in List.of(node.children)) {
      if (!_isBuilding || isCancelled()) break;
      queue.add(child);
    }
  }

  /// Preferred-setup candidate injection: quiet system moves (h4, Nh3, ...)
  /// are often missing from Maia/MultiPV top-N, so the selection tie-break
  /// would have nothing to choose.  Evaluate any legal setup move not
  /// already a candidate and add it, subject to the same eval-loss window
  /// as regular candidates.  [bestCpWhite] is the best candidate eval in
  /// white-POV centipawns (null = no reference, window not applied).
  Future<void> _injectSetupCandidates({
    required BuildTree tree,
    required BuildTreeNode node,
    required TreeBuildConfig config,
    required int? bestCpWhite,
    required void Function(BuildProgress) onProgress,
  }) async {
    final setup = parseSetupMoves(config.setupMoves);
    if (setup.isEmpty) return;
    final whiteToMove = isWhiteToMove(node.fen);

    for (final san in setup) {
      final uci = sanToUci(node.fen, san);
      if (uci == null) continue; // not legal here (or already played)
      final childFen = playUciMove(node.fen, uci);
      if (childFen == null) continue;
      if (node.children.any((c) => c.fen == childFen || c.moveUci == uci)) {
        continue; // already a candidate
      }

      // Child eval: Stockfish when available, else the DB eval chain
      // (matches how each build mode evaluates regular candidates).
      final int childCpWhite;
      final int evalDepthUsed;
      if (config.usesStockfish && _pool.workerCount > 0) {
        final result = await _pool.evaluateFen(childFen, config.evalDepth);
        _stats.sfMultipvCalls++;
        final childIsWhite = isWhiteToMove(childFen);
        childCpWhite =
            childIsWhite ? result.effectiveCp : -result.effectiveCp;
        evalDepthUsed = config.evalDepth;
      } else {
        final dbEval =
            await _evalResolver.lookupDbEvalWhite(childFen, config);
        if (dbEval == null) continue;
        childCpWhite = dbEval.$1;
        evalDepthUsed = dbEval.$2;
      }

      if (bestCpWhite != null) {
        final evalLoss = whiteToMove
            ? bestCpWhite - childCpWhite
            : childCpWhite - bestCpWhite;
        if (evalLoss > config.maxEvalLossCp) continue;
      }

      final child = _makeChild(
        parent: node,
        fen: childFen,
        san: uciToSan(node.fen, uci),
        uci: uci,
        tree: tree,
      );
      if (child == null) continue;

      child.moveProbability = 1.0;
      child.cumulativeProbability = node.cumulativeProbability;
      final childIsWhite = isWhiteToMove(childFen);
      child.engineEvalCp = childIsWhite ? childCpWhite : -childCpWhite;
      _evalResolver.cacheEvalWhite(childFen, childCpWhite, evalDepthUsed);

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

  /// Best-first priorities at an our-move node: the incumbent (best eval for
  /// us at expansion time) inherits the parent's priority; alternatives are
  /// discounted so they stay shallow unless the mainline budget runs out.
  void _assignOurMovePriorities(BuildTreeNode node, TreeBuildConfig config) {
    if (node.children.isEmpty) return;
    final basePri = effectiveSearchPriority(node);

    BuildTreeNode? incumbent;
    var bestCp = 0;
    for (final child in node.children) {
      final cp = child.evalForUs(config.playAsWhite);
      if (incumbent == null || cp > bestCp) {
        bestCp = cp;
        incumbent = child;
      }
    }
    for (final child in node.children) {
      child.searchPriority = identical(child, incumbent)
          ? basePri
          : basePri * config.ourAltDiscount;
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
    required FrontierQueue queue,
    bool coverageOnly = false,
  }) async {
    final mpvCount = node.ply == 0
        ? (config.ourMultipv >= 10 ? config.ourMultipv : 10)
        : config.ourMultipv;
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

    await _injectSetupCandidates(
      tree: tree,
      node: node,
      config: config,
      bestCpWhite: bestCp,
      onProgress: onProgress,
    );

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

    _assignOurMovePriorities(node, config);

    // Coverage-only: the answer is the deliverable — children stay
    // unexplored leaves so a future resume with more budget can deepen them.
    if (coverageOnly) return;

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
    required FrontierQueue queue,
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

  /// Maia policy for Dirichlet smoothing, or empty when smoothing is off,
  /// Maia is unavailable, or [totalGames] is large enough that the prior's
  /// weight would be negligible (saves the inference).
  Future<Map<String, double>> _maiaPolicyForSmoothing(
    String fen,
    int totalGames,
    TreeBuildConfig config,
  ) async {
    if (!smoothingWorthwhile(totalGames, config.maiaPriorGames)) {
      return const {};
    }
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
      return const {};
    }
    try {
      final sw = Stopwatch()..start();
      final result = await MaiaFactory.instance!.evaluate(fen, config.maiaElo);
      _stats.maiaEvals++;
      _stats.maiaTotalMs += sw.elapsedMilliseconds;
      return result.policy;
    } catch (e) {
      _log('Maia prior lookup failed: $e');
      return const {};
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

    // λ-smoothing: blend DB counts with Maia's policy so sparsely covered
    // positions degrade continuously toward Maia instead of trusting the
    // frequencies from a handful of games (or falling off a hard cliff).
    final maiaPolicy = await _maiaPolicyForSmoothing(
      node.fen,
      response.totalGames,
      config,
    );
    final smoothing = maiaPolicy.isNotEmpty;

    final candidates = smoothOpponentMoves(
      observed: [
        for (final m in response.moves)
          ObservedMove(
            uci: m.uci,
            san: m.san,
            games: m.total,
            whiteWins: m.white,
            blackWins: m.black,
            draws: m.draws,
          ),
      ],
      totalGames: response.totalGames,
      maiaPolicy: maiaPolicy,
      priorGames: smoothing ? config.maiaPriorGames : 0.0,
    );

    int childrenAdded = 0;
    double massCovered = 0.0;
    final massTarget = config.oppMassTarget;
    final basePri = effectiveSearchPriority(node);

    for (final move in candidates) {
      final prob = move.probability;
      final newCumul = node.cumulativeProbability * prob;
      // Coverage floor: replies at/above coverMinProb local probability must
      // exist in the tree regardless of budget cutoffs — they'll receive at
      // least a coverage-only answer instead of becoming a silent hole.
      final covered =
          config.coverMinProb > 0.0 && prob >= config.coverMinProb;
      if (!covered) {
        // The prior replaces the min-games noise filter when smoothing.
        if (!smoothing && move.games < config.minGames) continue;
        if (config.oppMaxChildren > 0 &&
            childrenAdded >= config.oppMaxChildren) {
          break;
        }
        if (massTarget > 0.0 && massCovered >= massTarget) break;
        if (newCumul < config.minProbability) continue;
      }

      final childFen = playUciMove(node.fen, move.uci);
      if (childFen == null) continue;

      final san = move.san.isNotEmpty ? move.san : uciToSan(node.fen, move.uci);
      final child = _makeChild(
        parent: node,
        fen: childFen,
        san: san,
        uci: move.uci,
        tree: tree,
      );
      if (child == null) continue;

      child.moveProbability = prob;
      child.cumulativeProbability = newCumul;
      child.searchPriority = basePri * prob;
      if (move.games > 0) {
        child.setLichessStats(move.whiteWins, move.blackWins, move.draws);
      }
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
    final basePri = effectiveSearchPriority(node);

    for (final entry in sortedMoves) {
      final uci = entry.key;
      final prob = entry.value;
      final newCumul = node.cumulativeProbability * prob;
      // Coverage floor: see _addOpponentChildrenFromLichess.
      final covered =
          config.coverMinProb > 0.0 && prob >= config.coverMinProb;
      if (!covered) {
        if (prob < config.maiaMinProb) continue;
        if (config.oppMaxChildren > 0 &&
            childrenAdded >= config.oppMaxChildren) {
          break;
        }
        if (massTarget > 0.0 && massCovered >= massTarget) break;
        if (newCumul < config.minProbability) continue;
      }

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
      child.searchPriority = basePri * prob;
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
    child.searchPriority = effectiveSearchPriority(node) * prob;
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
  Future<int> _coverageSweep({
    required BuildTree tree,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required void Function(BuildProgress) onProgress,
  }) async {
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
      if (!_isBuilding) break;

      final canonical = fenMap.getCanonical(group.first.fen);
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
      fenMap.putCanonical(rep.fen, rep);

      // The hole is worth answering if any path into this position carries
      // an opponent move at/above the coverage floor.
      var maxProb = 0.0;
      for (final n in group) {
        if (n.moveProbability > maxProb) maxProb = n.moveProbability;
      }
      for (final t in fenMap.getTranspositions(rep.fen)) {
        if (t.moveProbability > maxProb) maxProb = t.moveProbability;
      }

      if (maxProb >= config.coverMinProb) {
        if (config.buildMode == BuildMode.maiaDbExplore) {
          await _evalResolver.ensureEval(
            rep,
            config,
            fenMap: fenMap,
            pool: _pool,
            dbOnly: true,
          );
          await _buildOurMoveMaiaDb(
            tree: tree,
            node: rep,
            config: config,
            isCancelled: () => !_isBuilding,
            onProgress: onProgress,
            queue: throwawayQueue,
            coverageOnly: true,
          );
        } else if (_pool.workerCount > 0) {
          await _buildOurMove(
            tree: tree,
            node: rep,
            config: config,
            fenMap: fenMap,
            isCancelled: () => !_isBuilding,
            onProgress: onProgress,
            queue: throwawayQueue,
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

  // ── Prune eval-too-low (post-build cleanup) ────────────────────────────

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

  bool _fenKeysEqual(String fenA, String fenB) {
    return canonicalizeFen(fenA) == canonicalizeFen(fenB);
  }
}
