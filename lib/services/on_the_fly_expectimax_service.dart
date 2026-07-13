/// On-the-fly expectimax computation from arbitrary positions.
///
/// Auto-starts when expectimax is enabled. Tries eval DBs first (via
/// maiaDbExplore), then builds incrementally depth 1..N with per-move
/// line roll-in as each candidate finishes each depth.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/build_tree_node.dart';
import '../models/engine_settings.dart';
import '../models/eval_database_settings.dart';
import 'analysis_service.dart';
import 'expectimax_line_service.dart';
import 'generation/eca_calculator.dart';
import 'generation/fen_map.dart';
import 'generation/generation_config.dart';
import 'generation/tree_my_ease.dart';
import 'maia_factory.dart';
import 'tree_build_service.dart';

enum OnTheFlyState { idle, computing, ready, cancelled }

/// Snapshot of progressively rolled-in expectimax lines.
class OnTheFlyProgressiveLines {
  final List<ExpectimaxLine> lines;
  final int targetMaxDepth;
  final int? computingDepth;
  final int bestCompletedDepth;
  final bool isComputing;
  final String sourceLabel;
  final String? errorMessage;

  const OnTheFlyProgressiveLines({
    required this.lines,
    required this.targetMaxDepth,
    this.computingDepth,
    this.bestCompletedDepth = 0,
    this.isComputing = false,
    this.sourceLabel = 'on-the-fly',
    this.errorMessage,
  });
}

class _MoveLineState {
  final ExpectimaxLine line;
  final int lineDepth;

  const _MoveLineState({required this.line, required this.lineDepth});
}

class OnTheFlyExpectimaxService extends ChangeNotifier {
  final TreeBuildService _buildService = TreeBuildService();
  final EngineSettings _settings = EngineSettings.instance;

  /// Depth-1 pass runs at a reduced eval depth so first lines appear fast.
  static const int _firstPassMaxEvalDepth = 10;

  /// Watchdog per depth pass — surfaces an error instead of spinning forever
  /// if the pool or an engine worker stalls.
  static const Duration _depthPassTimeout = Duration(seconds: 60);

  /// Node budget per ply of target depth.  Generous enough that the
  /// interesting lines never hit it at typical on-the-fly depths (≤ 8);
  /// exists so a pathological position can't grow an unbounded tree while
  /// the user is just browsing.
  static const int _maxNodesPerPly = 800;

  /// Minimum interval between partial line refreshes during a depth pass —
  /// each refresh re-runs expectimax over the whole tree, so this bounds
  /// that cost while keeping the pane visibly live.
  static const Duration _partialRefreshInterval = Duration(milliseconds: 400);

  final Map<String, _CachedSubtree> _cache = {};
  final Map<String, _MoveLineState> _moveLines = {};

  OnTheFlyState _state = OnTheFlyState.idle;
  OnTheFlyState get state => _state;

  String? _currentFen;
  String? get currentFen => _currentFen;

  BuildTree? _currentTree;
  BuildTree? get currentTree => _currentTree;

  TreeBuildConfig? _currentConfig;
  TreeBuildConfig? get currentConfig => _currentConfig;

  FenMap? _currentFenMap;
  FenMap? get currentFenMap => _currentFenMap;

  int _targetMaxDepth = 5;
  int? _computingDepth;
  int _bestCompletedDepth = 0;
  int _nodesBuilt = 0;
  String _sourceLabel = 'on-the-fly';
  String? _lastError;

  int get nodesBuilt => _nodesBuilt;
  int? get computingDepth => _computingDepth;
  int get bestCompletedDepth => _bestCompletedDepth;

  int _runGeneration = 0;
  DateTime? _lastPartialNotify;

  OnTheFlyProgressiveLines get progressiveLines => OnTheFlyProgressiveLines(
        lines: _rankedLines(),
        targetMaxDepth: _targetMaxDepth,
        computingDepth: _computingDepth,
        bestCompletedDepth: _bestCompletedDepth,
        isComputing: _state == OnTheFlyState.computing,
        sourceLabel: _sourceLabel,
        errorMessage: _lastError,
      );

  /// Whether cached or in-flight data exists for [fen].
  bool hasDataForFen(String fen) =>
      _cache.containsKey(fen) || (_currentFen == fen && _moveLines.isNotEmpty);

  /// Start or continue auto computation for [fen].
  ///
  /// Tries [mainTree] first; otherwise builds on-the-fly depth-by-depth.
  Future<void> ensureRunning({
    required String fen,
    required bool playAsWhite,
    BuildTree? mainTree,
    TreeBuildConfig? mainConfig,
    FenMap? mainFenMap,
    int? maxDepth,
  }) async {
    final depth = maxDepth ?? _settings.onTheFlyMaxDepth;
    _targetMaxDepth = depth;

    if (_currentFen == fen && _state == OnTheFlyState.computing) {
      return;
    }

    if (_currentFen == fen &&
        _state == OnTheFlyState.ready &&
        _bestCompletedDepth >= depth &&
        _moveLines.isNotEmpty) {
      return;
    }

    // Session cache hit.
    if (_cache.containsKey(fen)) {
      _loadFromCache(fen);
      if (_bestCompletedDepth >= depth) return;
    }

    final gen = ++_runGeneration;

    _currentFen = fen;
    _moveLines.clear();
    _bestCompletedDepth = 0;
    _computingDepth = null;
    _sourceLabel = 'on-the-fly';
    _lastError = null;
    _state = OnTheFlyState.computing;
    notifyListeners();

    // Let the engine pane finish Maia + DB + discovery + eval first.
    await AnalysisService.instance.waitForEnginePaneAnalysis(fen);
    if (_runGeneration != gen) return;

    await _runProgressiveBuild(
      fen: fen,
      playAsWhite: playAsWhite,
      maxDepth: depth,
      generation: gen,
    );
  }

  /// Wait for a previous (timed-out or superseded) build on the shared
  /// builder to unwind.  The watchdog abandons build futures via
  /// `.timeout(...)`, so the underlying build may still hold the builder
  /// when the next run starts; without this, a quick retry dies on
  /// `StateError('A tree build is already running')`.
  Future<bool> _waitForBuilderIdle(int generation) async {
    const pollInterval = Duration(milliseconds: 50);
    final deadline = DateTime.now().add(_depthPassTimeout);
    while (_buildService.isBuilding) {
      _buildService.stopBuild();
      if (_runGeneration != generation) return false;
      if (DateTime.now().isAfter(deadline)) {
        _lastError = 'Previous expectimax build did not stop — '
            'engine may be stuck. Toggle expectimax to retry.';
        _state = OnTheFlyState.idle;
        notifyListeners();
        return false;
      }
      await Future.delayed(pollInterval);
    }
    return true;
  }

  Future<void> _runProgressiveBuild({
    required String fen,
    required bool playAsWhite,
    required int maxDepth,
    required int generation,
    EvalDatabaseSettings? dbSettings,
  }) async {
    if (!await _waitForBuilderIdle(generation)) return;

    BuildTree? tree;
    TreeBuildConfig? config;
    FenMap? fenMap;

    dbSettings ??= EvalDatabaseSettings.instance;
    if (!dbSettings.isLoaded) await dbSettings.load();

    // Wait for Maia to be initialized (avoid race condition on startup).
    if (MaiaFactory.isAvailable && MaiaFactory.instance != null) {
      try {
        await MaiaFactory.instance!.initialize();
      } catch (e) {
        debugPrint('[OnTheFlyExpectimax] Maia init failed: $e');
      }
    }

    // Use stockfishExpectimax by default — it works without an eval DB.
    // Only use maiaDbExplore when the user has a local DB configured.
    final hasEvalDb =
        dbSettings.enableCdbDirect && dbSettings.cdbDirectPath.isNotEmpty;
    final buildMode =
        hasEvalDb ? BuildMode.maiaDbExplore : BuildMode.stockfishExpectimax;
    debugPrint('[OnTheFlyExpectimax] buildMode=$buildMode '
        'hasEvalDb=$hasEvalDb');

    for (var depth = 1; depth <= maxDepth; depth++) {
      if (_runGeneration != generation || _state != OnTheFlyState.computing) {
        return;
      }

      _computingDepth = depth;
      _nodesBuilt = 0;
      notifyListeners();

      config = _buildConfig(
        fen: fen,
        playAsWhite: playAsWhite,
        maxPly: depth,
        dbSettings: dbSettings,
        buildMode: buildMode,
        // First pass at reduced depth so lines show up within seconds;
        // later passes refine at the configured depth.
        evalDepth: depth == 1
            ? math.min(_settings.expectimaxEvalDepth, _firstPassMaxEvalDepth)
            : _settings.expectimaxEvalDepth,
      );
      final activeConfig = config;

      debugPrint('[OnTheFlyExpectimax] depth=$depth/$maxDepth '
          'mode=$buildMode fen=${fen.split(' ').take(2).join(' ')}');

      // Un-explore leaf nodes at the previous depth boundary so the
      // build service will expand them at the new, deeper maxPly.
      // Also reset the fenMap so expanded nodes aren't treated as
      // transpositions of their previous (unexpanded) selves.
      if (tree != null && depth > 1) {
        _unexploreLeaves(tree.root, depth - 1);
        fenMap = null;
      }

      try {
        tree = await _buildService
            .build(
          config: activeConfig,
          existingTree: tree,
          onProgress: (progress) {
            if (_runGeneration != generation ||
                _state != OnTheFlyState.computing) {
              return;
            }
            _nodesBuilt = progress.totalNodes;
            final progressTree = _buildService.currentTree;
            if (progressTree == null) return;
            try {
              _maybeRefreshPartialLines(
                tree: progressTree,
                config: activeConfig,
                fenMap: fenMap,
                targetPly: depth,
                playAsWhite: playAsWhite,
                generation: generation,
              );
            } catch (e, st) {
              debugPrint(
                  '[OnTheFlyExpectimax] Partial refresh failed: $e\n$st');
            }
          },
          isCancelled: () =>
              _runGeneration != generation || _state != OnTheFlyState.computing,
        )
            // Watchdog: a stalled pool/worker must surface as an error, not
            // an eternal spinner.  The orphaned build unwinds via isCancelled
            // once state leaves `computing` below.
            .timeout(_depthPassTimeout);
      } on TimeoutException {
        if (_runGeneration == generation && _state == OnTheFlyState.computing) {
          debugPrint('[OnTheFlyExpectimax] Build TIMED OUT at depth $depth '
              'after ${_depthPassTimeout.inSeconds}s');
          _lastError = 'Timed out at depth $depth after '
              '${_depthPassTimeout.inSeconds}s — engine may be busy or stuck. '
              'Toggle expectimax to retry.';
          _state =
              _moveLines.isEmpty ? OnTheFlyState.idle : OnTheFlyState.ready;
          _computingDepth = null;
          notifyListeners();
        }
        return;
      } catch (e, st) {
        if (_runGeneration == generation && _state == OnTheFlyState.computing) {
          debugPrint(
              '[OnTheFlyExpectimax] Build FAILED at depth $depth: $e\n$st');
          _lastError = 'Build failed at depth $depth ($buildMode): $e';
          _state =
              _moveLines.isEmpty ? OnTheFlyState.idle : OnTheFlyState.ready;
          _computingDepth = null;
          notifyListeners();
        }
        return;
      }

      if (_runGeneration != generation || _state != OnTheFlyState.computing) {
        return;
      }

      final rootChildren = tree.root.children.length;
      final totalNodes = tree.totalNodes;
      debugPrint('[OnTheFlyExpectimax] depth=$depth/$maxDepth done: '
          '$rootChildren root children, $totalNodes total nodes');

      if (tree.root.children.isEmpty && depth == 1) {
        debugPrint('[OnTheFlyExpectimax] No moves found at depth 1 via '
            '$buildMode — check if Maia model is loaded or DB files exist');
        _lastError = 'No candidate moves found at depth 1 ($buildMode). '
            'Try switching candidate source to Stockfish in Study settings.';
        _state = OnTheFlyState.ready;
        _computingDepth = null;
        notifyListeners();
        return;
      }

      // Idempotent: re-populating registers only nodes added this pass.
      fenMap ??= FenMap();
      fenMap.populate(tree.root);

      final eca = ExpectimaxCalculator(config: config, fenMap: fenMap);
      eca.calculate(tree);
      calculateMyEase(tree, playAsWhite: playAsWhite);

      _currentTree = tree;
      _currentConfig = config;
      _currentFenMap = fenMap;

      _refreshMoveLines(
        tree: tree,
        config: config,
        fenMap: fenMap,
        targetPly: depth,
        forceAll: true,
      );

      _bestCompletedDepth = depth;
      final lines = _rankedLines();
      final maxLen = lines.fold<int>(
          0, (best, l) => l.movesSan.length > best ? l.movesSan.length : best);
      debugPrint('[OnTheFlyExpectimax] depth=$depth/$maxDepth complete: '
          '${lines.length} lines, longest=$maxLen moves');
      notifyListeners();
    }

    if (_runGeneration != generation || _state != OnTheFlyState.computing) {
      return;
    }

    if (tree != null && config != null && fenMap != null) {
      _cache[fen] = _CachedSubtree(
        tree: tree,
        config: config,
        fenMap: fenMap,
        completedDepth: maxDepth,
        moveLines: Map.from(_moveLines),
      );
    }

    _computingDepth = null;
    _state = OnTheFlyState.ready;
    notifyListeners();
  }

  void _maybeRefreshPartialLines({
    required BuildTree tree,
    required TreeBuildConfig config,
    required FenMap? fenMap,
    required int targetPly,
    required bool playAsWhite,
    required int generation,
  }) {
    final now = DateTime.now();
    if (_lastPartialNotify != null &&
        now.difference(_lastPartialNotify!) < _partialRefreshInterval) {
      return;
    }
    _lastPartialNotify = now;

    // Re-populate on every partial refresh: the tree grew since the last
    // tick and populate() is idempotent for already-registered nodes.
    final map = (fenMap ?? FenMap())..populate(tree.root);
    final eca = ExpectimaxCalculator(config: config, fenMap: map);
    eca.calculate(tree);
    calculateMyEase(tree, playAsWhite: playAsWhite);

    _currentTree = tree;
    _currentConfig = config;
    _currentFenMap = map;

    final changed = _refreshMoveLines(
      tree: tree,
      config: config,
      fenMap: map,
      targetPly: targetPly,
      forceAll: false,
    );

    if (changed && _runGeneration == generation) {
      notifyListeners();
    }
  }

  /// Update per-move lines for root children complete at [targetPly].
  /// Returns true if any line changed.
  bool _refreshMoveLines({
    required BuildTree tree,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required int targetPly,
    required bool forceAll,
  }) {
    final root = tree.root;
    final isOurTurn = root.isWhiteToMove == config.playAsWhite;

    if (!forceAll) {
      if (isOurTurn) {
        if (root.children.every((c) => !isBranchCompleteToPly(c, targetPly))) {
          return false;
        }
      } else if (!isBranchCompleteToPly(root, targetPly)) {
        return false;
      }
    }

    if (root.children.isEmpty) return false;

    final eca = ExpectimaxCalculator(config: config, fenMap: fenMap);
    final lines = generateExpectimaxLines(
      root,
      config,
      eca,
      topLines: _settings.expectimaxOurMultipv,
      maxPlies: targetPly,
      fenMap: fenMap,
    );

    var changed = false;
    for (final line in lines) {
      if (line.movesUci.isEmpty) continue;
      final key = line.movesUci.first;
      final prev = _moveLines[key];
      if (prev == null || targetPly > prev.lineDepth) {
        _moveLines[key] = _MoveLineState(line: line, lineDepth: targetPly);
        changed = true;
      }
    }
    return changed;
  }

  /// Reset `explored` on childless nodes at [previousMaxPly] so the build
  /// service will expand them on the next pass with a higher maxPly.
  static void _unexploreLeaves(BuildTreeNode node, int previousMaxPly) {
    if (node.children.isEmpty && node.ply >= previousMaxPly && node.explored) {
      node.explored = false;
      return;
    }
    for (final child in node.children) {
      _unexploreLeaves(child, previousMaxPly);
    }
  }

  List<ExpectimaxLine> _rankedLines() {
    final sorted = _moveLines.values.map((s) => s.line).toList()
      ..sort((a, b) => b.expectimaxValue.compareTo(a.expectimaxValue));

    return [
      for (var i = 0; i < sorted.length; i++) sorted[i].withRank(i + 1),
    ];
  }

  TreeBuildConfig _buildConfig({
    required String fen,
    required bool playAsWhite,
    required int maxPly,
    required EvalDatabaseSettings dbSettings,
    required BuildMode buildMode,
    required int evalDepth,
  }) {
    return TreeBuildConfig(
      startFen: fen,
      playAsWhite: playAsWhite,
      maxPly: maxPly,
      maxNodes: _maxNodesPerPly * maxPly,
      buildMode: buildMode,
      // 1 UCI thread per worker: parallelism comes from the pool's multiple
      // workers.  Anything >1 makes prepareForTreeBuild reconfigure workers
      // the interactive engine pane may be using (and leaves the whole pool
      // oversubscribed afterwards).
      engineThreads: 1,
      minProbability: _settings.expectimaxMinProb,
      maxEvalLossCp: _settings.expectimaxMaxEvalLoss,
      evalDepth: evalDepth,
      maiaElo: _settings.maiaElo,
      enableCdbDirect: dbSettings.enableCdbDirect,
      cdbDirectPath: dbSettings.cdbDirectPath,
      useLichessDb: true,
      ourMultipv: _settings.expectimaxOurMultipv,
      oppMaxChildren: _settings.expectimaxOppMaxChildren,
      oppMassTarget: _settings.expectimaxOppMassTarget,
    );
  }

  void _loadFromCache(String fen) {
    final cached = _cache[fen]!;
    _currentFen = fen;
    _currentTree = cached.tree;
    _currentConfig = cached.config;
    _currentFenMap = cached.fenMap;
    _moveLines
      ..clear()
      ..addAll(cached.moveLines);
    _bestCompletedDepth = cached.completedDepth;
    _computingDepth = null;
    _sourceLabel = 'cached';
    _state = OnTheFlyState.ready;
    notifyListeners();
  }

  void cancel() {
    if (_state == OnTheFlyState.computing) {
      _runGeneration++;
      _state =
          _moveLines.isEmpty ? OnTheFlyState.cancelled : OnTheFlyState.ready;
      _computingDepth = null;
      notifyListeners();
    }
  }

  void reset() {
    _runGeneration++;
    _state = OnTheFlyState.idle;
    _currentFen = null;
    _currentTree = null;
    _currentConfig = null;
    _currentFenMap = null;
    _moveLines.clear();
    _computingDepth = null;
    _bestCompletedDepth = 0;
    _nodesBuilt = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }
}

class _CachedSubtree {
  final BuildTree tree;
  final TreeBuildConfig config;
  final FenMap fenMap;
  final int completedDepth;
  final Map<String, _MoveLineState> moveLines;

  const _CachedSubtree({
    required this.tree,
    required this.config,
    required this.fenMap,
    required this.completedDepth,
    required this.moveLines,
  });
}
