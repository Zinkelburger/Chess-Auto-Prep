import '../../models/build_tree_node.dart';

/// Tracks and throttles Phase 1 BFS build progress callbacks.
class TreeBuildProgressTracker {
  int _lastProgressNodes = 0;
  int _lastProgressDequeues = 0;
  int _progressDequeueCount = 0;
  int _buildStartTotalNodes = 0;
  int _depthTracker = -1;

  void reset({required int buildStartTotalNodes}) {
    _lastProgressNodes = 0;
    _lastProgressDequeues = 0;
    _progressDequeueCount = 0;
    _buildStartTotalNodes = buildStartTotalNodes;
    _depthTracker = -1;
  }

  /// Seed depth display when resuming from a mid-tree frontier.
  void initForResume({required int minFrontierPly}) {
    _depthTracker = minFrontierPly - 1;
    _progressDequeueCount = 0;
    _lastProgressDequeues = 0;
  }

  void onDequeue(int ply) {
    _depthTracker = ply;
  }

  void emitProgress(
    BuildTree tree,
    int ply,
    String? fen,
    void Function(BuildProgress) onProgress,
    int maxPlyConfig, {
    required Stopwatch buildSw,
    bool fromDequeue = false,
    bool force = false,
  }) {
    if (!force) {
      if (fromDequeue) {
        _progressDequeueCount++;
        if (_progressDequeueCount - _lastProgressDequeues < 200) return;
        _lastProgressDequeues = _progressDequeueCount;
      } else if (tree.totalNodes - _lastProgressNodes < 5 &&
          tree.totalNodes > 2) {
        return;
      }
    }
    if (!fromDequeue) {
      _lastProgressNodes = tree.totalNodes;
    }

    final elapsedMs = buildSw.elapsedMilliseconds;
    final d = _depthTracker >= 0 ? _depthTracker : tree.maxPlyReached;

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

  /// Depth-layer stats for resume/progress UI before new nodes are added.
  static (int total, int unexplored) depthLayerStats(
    BuildTreeNode root,
    int targetPly,
  ) {
    int total = 0;
    int unexplored = 0;
    _walkDepthLayer(root, targetPly, (n) {
      total++;
      if (!n.explored) unexplored++;
    });
    return (total, unexplored);
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
}
