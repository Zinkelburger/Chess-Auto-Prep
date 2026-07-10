import 'dart:math' as math;

import '../../models/build_tree_node.dart';

/// Tracks and throttles Phase 1 build progress callbacks.
///
/// FIFO (Pure Expectimax) progress is depth-layer based: the BFS completes
/// ply layers in order, so "N/M explored at depth d" and a per-depth ETA
/// are meaningful.
///
/// Best-first (Fast Expectimax) fills all depths concurrently, so layer
/// stats flicker and never complete in order.  Instead the tracker exploits
/// a max-heap invariant: children enqueue with priority ≤ their parent's,
/// so the popped priority descends monotonically from 1.0 to the search
/// floor — mapping its logarithm onto [0, 1] gives an honest whole-run
/// progress fraction, and the recent descent rate gives a whole-run ETA.
class TreeBuildProgressTracker {
  /// Minimum wall-clock gap between emitted progress events.  Each emit
  /// walks the tree once (O(n)) to build the per-ply histogram, so this is
  /// time-based rather than node-count-based to keep the walk cost bounded
  /// on fast-growing trees.
  static const int _emitIntervalMs = 250;

  /// Sliding window over which the priority-descent rate (whole-run ETA)
  /// is measured.
  static const int _etaWindowMs = 60000;

  /// Log-scale floor used when minProbability is 0 (the mapping needs a
  /// finite endpoint).
  static const double _fallbackFloor = 1e-6;

  int _lastEmitMs = -_emitIntervalMs;
  int _buildStartTotalNodes = 0;
  int _depthTracker = -1;

  bool _bestFirst = false;
  double _priorityFloor = _fallbackFloor;
  double _lastPoppedPriority = -1.0;
  int _frontierSize = 0;

  /// (elapsedMs, priorityProgress) samples inside the ETA window.
  final List<(int, double)> _progressSamples = [];

  void reset({
    required int buildStartTotalNodes,
    bool bestFirst = false,
    double minProbability = 0.0,
  }) {
    _lastEmitMs = -_emitIntervalMs;
    _buildStartTotalNodes = buildStartTotalNodes;
    _depthTracker = -1;
    _bestFirst = bestFirst;
    _priorityFloor =
        minProbability > 0 ? minProbability : _fallbackFloor;
    _lastPoppedPriority = -1.0;
    _frontierSize = 0;
    _progressSamples.clear();
  }

  /// Seed depth display when resuming from a mid-tree frontier.
  void initForResume({required int minFrontierPly}) {
    _depthTracker = minFrontierPly - 1;
  }

  void onDequeue(int ply, {double priority = -1.0, int frontierSize = -1}) {
    _depthTracker = ply;
    if (priority >= 0.0) _lastPoppedPriority = priority;
    if (frontierSize >= 0) _frontierSize = frontierSize;
  }

  void emitProgress(
    BuildTree tree,
    int ply,
    String? fen,
    void Function(BuildProgress) onProgress,
    int maxPlyConfig, {
    required Stopwatch buildSw,
    bool force = false,
  }) {
    final elapsedMs = buildSw.elapsedMilliseconds;
    if (!force && elapsedMs - _lastEmitMs < _emitIntervalMs) return;
    _lastEmitMs = elapsedMs;

    final (totals, explored) = depthHistogram(tree.root);

    double? nodesPerMinute;
    final elapsedMin = elapsedMs / 60000.0;
    final deltaNodes = tree.totalNodes - _buildStartTotalNodes;
    if (elapsedMs >= 500 && elapsedMin > 0 && deltaNodes >= 1) {
      nodesPerMinute = deltaNodes / elapsedMin;
    }

    int currentDepth;
    int totalAtDepth = 0;
    int unexploredAtDepth = 0;
    int? etaDepthSeconds;
    double? priorityProgress;
    int? etaRunSeconds;

    if (_bestFirst) {
      currentDepth = tree.maxPlyReached;
      priorityProgress = _priorityProgress();
      if (priorityProgress != null) {
        etaRunSeconds = _updateEtaSamples(elapsedMs, priorityProgress);
      }
    } else {
      currentDepth = _depthTracker >= 0 ? _depthTracker : tree.maxPlyReached;
      if (currentDepth >= 0 && currentDepth < totals.length) {
        totalAtDepth = totals[currentDepth];
        unexploredAtDepth = totalAtDepth - explored[currentDepth];
      }
      if (nodesPerMinute != null &&
          nodesPerMinute > 0 &&
          unexploredAtDepth > 0) {
        etaDepthSeconds = (unexploredAtDepth * 60.0 / nodesPerMinute)
            .round()
            .clamp(1, 86400 * 7);
      }
    }

    onProgress(BuildProgress(
      totalNodes: tree.totalNodes,
      maxPlyReached: tree.maxPlyReached,
      maxPlyConfig: maxPlyConfig,
      elapsedMs: elapsedMs,
      nodesPerMinute: nodesPerMinute,
      currentDepth: currentDepth,
      unexploredAtDepth: unexploredAtDepth,
      totalAtDepth: totalAtDepth,
      etaDepthSeconds: etaDepthSeconds,
      bestFirst: _bestFirst,
      frontierSize: _frontierSize,
      priorityProgress: priorityProgress,
      etaRunSeconds: etaRunSeconds,
      depthTotals: totals,
      depthExplored: explored,
    ));
  }

  /// Log-scale position of the popped priority between 1.0 and the search
  /// floor.  Monotone non-increasing pops make this monotone non-decreasing.
  double? _priorityProgress() {
    final p = _lastPoppedPriority;
    if (p < 0.0) return null;
    if (p >= 1.0) return 0.0;
    final floorLn = math.log(_priorityFloor);
    if (p <= _priorityFloor) return 1.0;
    return (math.log(p) / floorLn).clamp(0.0, 1.0);
  }

  /// Record a progress sample and return the whole-run ETA from the descent
  /// rate over the recent window, or null while the rate is unknown/zero.
  int? _updateEtaSamples(int elapsedMs, double progress) {
    _progressSamples.add((elapsedMs, progress));
    while (_progressSamples.length > 2 &&
        _progressSamples.first.$1 < elapsedMs - _etaWindowMs) {
      _progressSamples.removeAt(0);
    }
    final first = _progressSamples.first;
    final deltaMs = elapsedMs - first.$1;
    final deltaProgress = progress - first.$2;
    if (deltaMs < 1000 || deltaProgress <= 0) return null;
    final remainingMs = (1.0 - progress) * deltaMs / deltaProgress;
    return (remainingMs / 1000).round().clamp(1, 86400 * 7);
  }

  /// Per-ply total and explored node counts, index = ply.
  static (List<int>, List<int>) depthHistogram(BuildTreeNode root) {
    final totals = <int>[];
    final explored = <int>[];
    void walk(BuildTreeNode node) {
      while (totals.length <= node.ply) {
        totals.add(0);
        explored.add(0);
      }
      totals[node.ply]++;
      if (node.explored) explored[node.ply]++;
      for (final c in node.children) {
        walk(c);
      }
    }

    walk(root);
    return (totals, explored);
  }

  /// Depth-layer stats for resume/progress UI before new nodes are added.
  static (int total, int unexplored) depthLayerStats(
    BuildTreeNode root,
    int targetPly,
  ) {
    final (totals, explored) = depthHistogram(root);
    if (targetPly < 0 || targetPly >= totals.length) return (0, 0);
    return (totals[targetPly], totals[targetPly] - explored[targetPly]);
  }
}
