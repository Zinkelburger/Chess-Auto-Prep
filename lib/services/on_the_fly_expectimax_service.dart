/// On-the-fly expectimax computation from arbitrary positions.
///
/// Auto-starts when expectimax is enabled.  Reuses any subtree already built
/// for the position (previous run, session cache, or the main generated
/// tree) as an instantly displayed seed, then runs ONE anytime best-first
/// build pass to the target depth — the frontier expands the most probable
/// branches first, and each root move's line rolls in as its branch
/// completes.  Only when no seed exists does a shallow reduced-depth first
/// pass put candidate lines on screen within seconds.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/build_tree_node.dart';
import '../models/engine_settings.dart';
import '../models/eval_database_settings.dart';
import 'analysis_service.dart';
import 'expectimax_line_service.dart';
import 'generation/build_subtree.dart';
import 'generation/eca_calculator.dart';
import 'generation/fen_map.dart';
import 'generation/generation_config.dart';
import 'generation/tree_my_ease.dart';
import 'maia/maia_factory.dart';
import 'tree_build_service.dart';
import '../utils/safe_change_notifier.dart';

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

  /// Ply this root move's branch was fully explored to when [line] was
  /// generated (the line itself may extend further through best-first PV
  /// structure that is still refining).
  final int lineDepth;

  const _MoveLineState({required this.line, required this.lineDepth});
}

class OnTheFlyExpectimaxService extends ChangeNotifier with SafeChangeNotifier {
  final TreeBuildService _buildService = TreeBuildService();
  final EngineSettings _settings = EngineSettings.instance;

  OnTheFlyExpectimaxService() {
    _settings.addListener(_onEngineSettingsChanged);
  }

  /// Seedless first pass runs at a reduced eval depth so lines appear fast.
  static const int _firstPassMaxEvalDepth = 10;

  /// Watchdog: fail the run when the builder reports no progress for this
  /// long, instead of spinning forever behind a stalled pool or worker.
  static const Duration _stallTimeout = Duration(seconds: 60);

  /// How often the watchdog re-checks an in-flight build pass.
  static const Duration _stallPollInterval = Duration(seconds: 5);

  /// Node budget per ply of target depth.  Generous enough that the
  /// interesting lines never hit it at typical on-the-fly depths (≤ 8);
  /// exists so a pathological position can't grow an unbounded tree while
  /// the user is just browsing.
  static const int _maxNodesPerPly = 800;

  /// Base / max interval between partial line refreshes during a build
  /// pass.  Each refresh re-runs O(nodes) expectimax over the whole tree on
  /// the UI isolate, so the cadence stretches as the tree grows — small
  /// trees stay snappy while a large one can't repaint the whole pane
  /// several times a second.
  static const Duration _partialRefreshBase = Duration(milliseconds: 400);
  static const Duration _partialRefreshMax = Duration(milliseconds: 1500);

  Duration get _partialRefreshInterval {
    final ms = (_partialRefreshBase.inMilliseconds + _nodesBuilt ~/ 4).clamp(
      _partialRefreshBase.inMilliseconds,
      _partialRefreshMax.inMilliseconds,
    );
    return Duration(milliseconds: ms);
  }

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

  /// Search mode ([EngineSettings.expectimaxFastSearch]) the current tree
  /// and session cache were built with.  A flip invalidates both — Fast and
  /// Pure grow differently shaped trees, and resuming one under the other
  /// would silently keep the old shape everywhere already explored.
  bool? _builtWithFastSearch;

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
  /// Any already-built subtree containing [fen] — the previous position's
  /// tree, a session-cached result, or [mainTree] — seeds the run: its lines
  /// display immediately and the build only deepens what is missing.
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

    _builtWithFastSearch = _settings.expectimaxFastSearch;

    if (_currentFen == fen && _state == OnTheFlyState.computing) {
      return;
    }

    if (_currentFen == fen &&
        _state == OnTheFlyState.ready &&
        _bestCompletedDepth >= depth &&
        _moveLines.isNotEmpty) {
      return;
    }

    // Reuse previous work.  A clone keeps the source tree immutable while
    // the resumed build mutates the copy.
    BuildTree? seed;
    if (_cache.containsKey(fen)) {
      _loadFromCache(fen);
      if (_bestCompletedDepth >= depth) return;
      seed = extractRebasedSubtree(
        _cache[fen]!.tree.root,
        playAsWhite: playAsWhite,
      );
    } else {
      seed = _extractSeed(fen, playAsWhite, mainTree: mainTree);
    }

    final gen = ++_runGeneration;

    _currentFen = fen;
    _moveLines.clear();
    _bestCompletedDepth = 0;
    _computingDepth = null;
    _sourceLabel = seed != null ? 'reused' : 'on-the-fly';
    _lastError = null;
    _state = OnTheFlyState.computing;

    if (seed != null) {
      // Depth-capped leaves from the previous pass must count as frontier,
      // not as finished branches, before completeness is measured.
      reopenExpansionLeaves(seed.root, belowPly: depth);
      _finalizeDisplay(
        tree: seed,
        config: _displayConfig(
          fen: fen,
          playAsWhite: playAsWhite,
          depth: depth,
        ),
        cap: depth,
        playAsWhite: playAsWhite,
        withMyEase: true,
      );
      if (_bestCompletedDepth >= depth && _moveLines.isNotEmpty) {
        // The reused subtree already covers the target depth — no build.
        _cache[fen] = _CachedSubtree(
          tree: seed,
          config: _currentConfig!,
          fenMap: _currentFenMap!,
          completedDepth: depth,
          moveLines: Map.from(_moveLines),
        );
        _state = OnTheFlyState.ready;
        notifyListeners();
        return;
      }
    }
    notifyListeners();

    // Let the engine pane finish Maia + DB + discovery + eval first.  Seed
    // lines (if any) stay on screen during the wait.
    await AnalysisService.instance.waitForEnginePaneAnalysis(fen);
    if (_runGeneration != gen) return;

    await _runProgressiveBuild(
      fen: fen,
      playAsWhite: playAsWhite,
      maxDepth: depth,
      generation: gen,
      seed: seed,
    );
  }

  /// Find [fen] inside any tree this service has already seen and clone its
  /// subtree, rebased to ply 0, as a build seed.  Sources in order: the
  /// current (possibly superseded mid-build) tree, session-cached results,
  /// then the main generated tree.
  BuildTree? _extractSeed(String fen, bool playAsWhite, {BuildTree? mainTree}) {
    BuildTreeNode? locate(BuildTree? tree, FenMap? map) {
      if (tree == null) return null;
      var node = map?.getCanonical(fen);
      if (node == null || node.children.isEmpty) {
        node = findNodeByFen(tree, fen);
      }
      if (node == null || node.children.isEmpty) return null;
      return node;
    }

    var source = locate(_currentTree, _currentFenMap);
    if (source == null) {
      for (final cached in _cache.values) {
        source = locate(cached.tree, cached.fenMap);
        if (source != null) break;
      }
    }
    source ??= locate(mainTree, null);
    if (source == null) return null;

    final seed = extractRebasedSubtree(source, playAsWhite: playAsWhite);
    debugPrint(
      '[OnTheFlyExpectimax] Seeding from existing subtree '
      '(${seed.totalNodes} nodes)',
    );
    return seed;
  }

  /// Wait for a previous (stalled or superseded) build on the shared
  /// builder to unwind.  A stall abandons build futures, so the underlying
  /// build may still hold the builder when the next run starts; without
  /// this, a quick retry dies on `StateError('A tree build is already
  /// running')`.
  Future<bool> _waitForBuilderIdle(int generation) async {
    const pollInterval = Duration(milliseconds: 50);
    final deadline = DateTime.now().add(_stallTimeout);
    while (_buildService.isBuilding) {
      _buildService.stopBuild();
      if (_runGeneration != generation) return false;
      if (DateTime.now().isAfter(deadline)) {
        _failRun(
          'Previous expectimax build did not stop — '
          'engine may be stuck. Toggle expectimax to retry.',
        );
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
    BuildTree? seed,
  }) async {
    if (!await _waitForBuilderIdle(generation)) return;

    final dbSettings = EvalDatabaseSettings.instance;
    if (!dbSettings.isLoaded) await dbSettings.load();

    // Wait for Maia to be initialized (avoid race condition on startup).
    if (MaiaFactory.isAvailable && MaiaFactory.instance != null) {
      try {
        await MaiaFactory.instance!.initialize();
      } catch (e) {
        debugPrint('[OnTheFlyExpectimax] Maia init failed: $e');
      }
    }
    if (_bailed(generation)) return;

    // Use stockfishExpectimax by default — it works without an eval DB.
    // Only use maiaDbExplore when the user has a local DB configured.
    final hasEvalDb =
        dbSettings.enableCdbDirect && dbSettings.cdbDirectPath.isNotEmpty;
    final buildMode = hasEvalDb
        ? BuildMode.maiaDbExplore
        : BuildMode.stockfishExpectimax;
    debugPrint(
      '[OnTheFlyExpectimax] buildMode=$buildMode hasEvalDb=$hasEvalDb '
      'seed=${seed?.totalNodes ?? 0} nodes '
      'fen=${fen.split(' ').take(2).join(' ')}',
    );

    var tree = seed;

    // No reusable subtree: a shallow reduced-depth pass puts candidate
    // lines on screen within seconds before the deep pass refines them.
    if (tree == null) {
      _computingDepth = 1;
      _nodesBuilt = 0;
      notifyListeners();

      final quickConfig = _buildConfig(
        fen: fen,
        playAsWhite: playAsWhite,
        maxPly: 1,
        dbSettings: dbSettings,
        buildMode: buildMode,
        evalDepth: math.min(
          _settings.expectimaxEvalDepth,
          _firstPassMaxEvalDepth,
        ),
      );
      tree = await _runBuildPass(
        config: quickConfig,
        generation: generation,
        cap: 1,
      );
      if (tree == null || _bailed(generation)) return;

      if (tree.root.children.isEmpty) {
        debugPrint(
          '[OnTheFlyExpectimax] No moves found via $buildMode — '
          'check if Maia model is loaded or DB files exist',
        );
        _lastError =
            'No candidate moves found ($buildMode). '
            'Try switching candidate source to Stockfish in Study settings.';
        _state = OnTheFlyState.ready;
        _computingDepth = null;
        notifyListeners();
        return;
      }

      _finalizeDisplay(
        tree: tree,
        config: quickConfig,
        cap: 1,
        playAsWhite: playAsWhite,
      );
      notifyListeners();
    }

    // One anytime deep pass to the target depth: the best-first frontier
    // grows the most probable branches first, and lines roll in per branch
    // as they complete — no depth-by-depth rebuilds.
    final deepConfig = _buildConfig(
      fen: fen,
      playAsWhite: playAsWhite,
      maxPly: maxDepth,
      dbSettings: dbSettings,
      buildMode: buildMode,
      evalDepth: _settings.expectimaxEvalDepth,
      existingNodes: tree.totalNodes,
    );
    if (maxDepth > 1) {
      reopenExpansionLeaves(tree.root, belowPly: maxDepth);
      _computingDepth = maxDepth;
      _nodesBuilt = tree.totalNodes;
      notifyListeners();

      final deepened = await _runBuildPass(
        config: deepConfig,
        existingTree: tree,
        generation: generation,
        cap: maxDepth,
      );
      if (deepened == null || _bailed(generation)) return;
      tree = deepened;
    }

    _finalizeDisplay(
      tree: tree,
      config: deepConfig,
      cap: maxDepth,
      playAsWhite: playAsWhite,
      withMyEase: true,
    );
    _bestCompletedDepth = maxDepth;
    _cache[fen] = _CachedSubtree(
      tree: tree,
      config: deepConfig,
      fenMap: _currentFenMap!,
      completedDepth: maxDepth,
      moveLines: Map.from(_moveLines),
    );
    _computingDepth = null;
    _state = OnTheFlyState.ready;
    debugPrint(
      '[OnTheFlyExpectimax] complete: ${_moveLines.length} lines, '
      '${tree.totalNodes} nodes',
    );
    notifyListeners();
  }

  bool _bailed(int generation) =>
      _runGeneration != generation || _state != OnTheFlyState.computing;

  /// Run one build pass with partial line roll-in and a stall watchdog.
  ///
  /// Returns the (possibly partial) tree, or null when the pass was
  /// superseded, stalled, or failed — error state is already set where the
  /// run is still current.
  Future<BuildTree?> _runBuildPass({
    required TreeBuildConfig config,
    required int generation,
    required int cap,
    BuildTree? existingTree,
  }) async {
    var lastProgressAt = DateTime.now();

    final future = _buildService.build(
      config: config,
      existingTree: existingTree,
      onProgress: (progress) {
        lastProgressAt = DateTime.now();
        if (_bailed(generation)) return;
        _nodesBuilt = progress.totalNodes;
        final progressTree = _buildService.currentTree;
        if (progressTree == null) return;
        try {
          _maybeRefreshPartialLines(
            tree: progressTree,
            config: config,
            cap: cap,
            generation: generation,
          );
        } catch (e, st) {
          debugPrint('[OnTheFlyExpectimax] Partial refresh failed: $e\n$st');
        }
      },
      isCancelled: () => _bailed(generation),
    );

    while (true) {
      try {
        return await future.timeout(_stallPollInterval);
      } on TimeoutException {
        // Superseded runs unwind on their own via isCancelled.
        if (_bailed(generation)) {
          future.ignore();
          return null;
        }
        if (DateTime.now().difference(lastProgressAt) >= _stallTimeout) {
          debugPrint(
            '[OnTheFlyExpectimax] Build stalled: no progress for '
            '${_stallTimeout.inSeconds}s',
          );
          // Best effort; if the builder is hung inside an engine call,
          // _waitForBuilderIdle picks the orphan up on the next run.
          _buildService.stopBuild();
          future.ignore();
          _failRun(
            'Expectimax made no progress for ${_stallTimeout.inSeconds}s — '
            'engine may be busy or stuck. Toggle expectimax to retry.',
          );
          return null;
        }
      } on BuildCancelledException {
        return null;
      } catch (e, st) {
        debugPrint('[OnTheFlyExpectimax] Build FAILED: $e\n$st');
        if (!_bailed(generation)) {
          _failRun('Build failed (${config.buildMode}): $e');
        }
        return null;
      }
    }
  }

  void _failRun(String message) {
    _lastError = message;
    _state = _moveLines.isEmpty ? OnTheFlyState.idle : OnTheFlyState.ready;
    _computingDepth = null;
    notifyListeners();
  }

  void _maybeRefreshPartialLines({
    required BuildTree tree,
    required TreeBuildConfig config,
    required int cap,
    required int generation,
  }) {
    final now = DateTime.now();
    if (_lastPartialNotify != null &&
        now.difference(_lastPartialNotify!) < _partialRefreshInterval) {
      return;
    }
    _lastPartialNotify = now;

    // Fresh map every refresh: canonical/transposition roles shift as the
    // tree grows, and a stale canonical entry would hide continuations.
    final map = FenMap()..populate(tree.root);
    ExpectimaxCalculator(config: config, fenMap: map).calculate(tree);
    // myEase is not read by the progressive line display (it renders `.ease`)
    // and is recomputed when the pass finishes — skip its full-tree walk
    // here to keep each partial tick cheap.

    _currentTree = tree;
    _currentConfig = config;
    _currentFenMap = map;

    final changed = _refreshMoveLines(
      tree: tree,
      config: config,
      fenMap: map,
      cap: cap,
      forceAll: false,
    );

    if (changed && _runGeneration == generation) {
      notifyListeners();
    }
  }

  /// Recompute expectimax over [tree] and rebuild the per-move lines.
  /// Sets the current display references as one atomic step.
  void _finalizeDisplay({
    required BuildTree tree,
    required TreeBuildConfig config,
    required int cap,
    required bool playAsWhite,
    bool withMyEase = false,
  }) {
    final fenMap = FenMap()..populate(tree.root);
    ExpectimaxCalculator(config: config, fenMap: fenMap).calculate(tree);
    if (withMyEase) calculateMyEase(tree, playAsWhite: playAsWhite);

    _currentTree = tree;
    _currentConfig = config;
    _currentFenMap = fenMap;

    _refreshMoveLines(
      tree: tree,
      config: config,
      fenMap: fenMap,
      cap: cap,
      forceAll: true,
    );
  }

  /// Update per-root-move lines.  Each root move's line refreshes once its
  /// branch completeness reaches the depth it last rendered at (monotone —
  /// no depth regressions mid-build); lines themselves always follow the
  /// full available continuation up to [cap] plies.  Returns true when any
  /// displayed line changed.
  bool _refreshMoveLines({
    required BuildTree tree,
    required TreeBuildConfig config,
    required FenMap fenMap,
    required int cap,
    required bool forceAll,
  }) {
    final root = tree.root;
    if (root.children.isEmpty) return false;

    final eca = ExpectimaxCalculator(config: config, fenMap: fenMap);
    var changed = false;
    var minCompleted = cap;
    final liveKeys = <String>{};

    for (final child in root.children) {
      liveKeys.add(child.moveUci);
      final completed = branchCompletePly(child, cap);
      if (completed < minCompleted) minCompleted = completed;

      final prev = _moveLines[child.moveUci];
      if (!forceAll && prev != null && completed < prev.lineDepth) continue;

      final line = generateLineForFirstMove(
        root,
        child,
        config,
        eca,
        maxPlies: cap,
        fenMap: fenMap,
      );
      if (line == null) continue; // no expectimax on this child yet

      final differs =
          prev == null ||
          prev.line.expectedEvalCp != line.expectedEvalCp ||
          !listEquals(prev.line.movesUci, line.movesUci);
      _moveLines[child.moveUci] = _MoveLineState(
        line: line,
        lineDepth: completed,
      );
      if (differs) changed = true;
    }

    // Drop lines whose root move no longer exists (post-build prune).
    if (forceAll && _moveLines.keys.any((k) => !liveKeys.contains(k))) {
      _moveLines.removeWhere((k, _) => !liveKeys.contains(k));
      changed = true;
    }

    if (minCompleted > _bestCompletedDepth) {
      _bestCompletedDepth = minCompleted;
      changed = true;
    }
    return changed;
  }

  List<ExpectimaxLine> _rankedLines() {
    final sorted = _moveLines.values.map((s) => s.line).toList()
      ..sort((a, b) => b.expectimaxValue.compareTo(a.expectimaxValue));

    return [for (var i = 0; i < sorted.length; i++) sorted[i].withRank(i + 1)];
  }

  /// Config used only to score/display a seed before the real pass config
  /// exists (eval-DB settings may not be loaded yet — display math does not
  /// depend on build mode or eval sources).
  TreeBuildConfig _displayConfig({
    required String fen,
    required bool playAsWhite,
    required int depth,
  }) {
    return _buildConfig(
      fen: fen,
      playAsWhite: playAsWhite,
      maxPly: depth,
      dbSettings: EvalDatabaseSettings.instance,
      buildMode: BuildMode.stockfishExpectimax,
      evalDepth: _settings.expectimaxEvalDepth,
    );
  }

  TreeBuildConfig _buildConfig({
    required String fen,
    required bool playAsWhite,
    required int maxPly,
    required EvalDatabaseSettings dbSettings,
    required BuildMode buildMode,
    required int evalDepth,
    int existingNodes = 0,
  }) {
    return TreeBuildConfig(
      startFen: fen,
      playAsWhite: playAsWhite,
      maxPly: maxPly,
      // A reused seed's nodes must not eat the growth budget of the pass
      // that resumes from it.
      maxNodes: _maxNodesPerPly * maxPly + existingNodes,
      buildMode: buildMode,
      // 1 UCI thread per worker: parallelism comes from the pool's multiple
      // workers.  Anything >1 makes prepareForTreeBuild reconfigure workers
      // the interactive engine pane may be using (and leaves the whole pool
      // oversubscribed afterwards).
      engineThreads: 1,
      searchAlgorithm: _settings.expectimaxFastSearch
          ? SearchAlgorithm.fast
          : SearchAlgorithm.pure,
      minProbability: _settings.expectimaxMinProb,
      maxEvalLossCp: _settings.expectimaxMaxEvalLoss,
      evalDepth: evalDepth,
      maiaElo: _settings.maiaElo,
      enableCdbDirect: dbSettings.enableCdbDirect,
      cdbDirectPath: dbSettings.cdbDirectPath,
      ourMultipv: _settings.expectimaxOurMultipv,
      oppMaxChildren: _settings.expectimaxOppMaxChildren,
      oppMassTarget: _settings.expectimaxOppMassTarget,
      // Tight per-ply node budget: spend it on depth, not opening breadth
      // (the analyzed position is the root and is wide regardless).
      openingWidthPlies: 0,
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

  /// A Fast↔Pure flip discards everything: the two modes grow differently
  /// shaped trees, and resuming one under the other would silently keep the
  /// old shape everywhere already explored.  Dropping to idle also lets the
  /// panel hosts (which early-out while data exists for the current FEN)
  /// restart compute under the new mode.
  void _onEngineSettingsChanged() {
    final fast = _settings.expectimaxFastSearch;
    if (_builtWithFastSearch == null || _builtWithFastSearch == fast) {
      return;
    }
    _builtWithFastSearch = fast;
    _runGeneration++;
    _cache.clear();
    _currentFen = null;
    _currentTree = null;
    _currentConfig = null;
    _currentFenMap = null;
    _moveLines.clear();
    _bestCompletedDepth = 0;
    _computingDepth = null;
    _state = OnTheFlyState.idle;
    notifyListeners();
  }

  void cancel() {
    if (_state == OnTheFlyState.computing) {
      _runGeneration++;
      _state = _moveLines.isEmpty
          ? OnTheFlyState.cancelled
          : OnTheFlyState.ready;
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
    _settings.removeListener(_onEngineSettingsChanged);
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
