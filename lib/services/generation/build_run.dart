/// Per-run state for a single tree build.
///
/// [BuildRun] is the context object threaded through the build loop and the
/// per-mode [NodeExpander]s.  It owns everything that must exist exactly
/// once per run — the cancellation token, the stopwatch, the node-id
/// allocator, statistics, the debug log, and progress emission — so the
/// expansion code never reaches back into `TreeBuildService` instance
/// fields.  This is what makes concurrent misuse (two builds sharing one
/// service) fail loudly at the entry point instead of corrupting state.
library;

import '../../models/build_tree_node.dart';
import '../../utils/fen_utils.dart';
import '../engine/stockfish_pool.dart';
import 'generation_config.dart';
import 'run_debug_dump.dart';
import 'fen_map.dart';
import 'tree_build_progress.dart';
import 'tree_eval_resolver.dart';

/// Unified cancellation token for one build run.
///
/// A build stops for exactly one of two reasons and every loop must honor
/// both: the owner called `TreeBuildService.stopBuild()` ([stopRequested]),
/// or the caller's `isCancelled` callback flipped ([externallyCancelled]).
/// Historically these were checked inconsistently (`_isBuilding` here, the
/// callback there), which let a callback-cancelled build keep sweeping.
/// Check [isCancelled] and nothing else.
class BuildCancellation {
  final bool Function() _external;
  bool _stopRequested = false;

  BuildCancellation({bool Function()? isCancelledExternally})
    : _external = isCancelledExternally ?? (() => false);

  /// True once `stopBuild()` was called on the owning service.
  bool get stopRequested => _stopRequested;

  /// True when the caller's cancel callback reports cancellation.
  bool get externallyCancelled => _external();

  /// The one check every build loop uses.
  bool get isCancelled => _stopRequested || _external();

  void requestStop() => _stopRequested = true;
}

/// State owned by one call to `build()` / `buildFromPgnFreqMap()`.
class BuildRun {
  /// Effective config.  Mutable because `relativeEval` shifts the eval
  /// window once the root eval is known.
  TreeBuildConfig config;

  final BuildTree tree;
  final FenMap fenMap;
  final StockfishPool pool;
  final TreeEvalResolver evalResolver;
  final BuildStats stats;
  final RunDebugLog runLog;
  final TreeBuildProgressTracker progress;
  final void Function(BuildProgress) onProgress;
  final BuildCancellation cancel;

  /// Stops BFS expansion but still runs the coverage sweep and post-build
  /// prune (unlike [cancel], which abandons downstream phases).
  final bool Function() finishNow;

  /// Pause gate, provided by the owning service — pause outlives a single
  /// run (phase 2 shares it), so the service owns the completer.
  final Future<void> Function() waitIfPaused;

  /// Active-build stopwatch; the service pauses it with the pause gate.
  final Stopwatch stopwatch = Stopwatch();

  /// Next node id to allocate; [makeChild] is the only writer during a run.
  int nextNodeId;

  BuildRun({
    required this.config,
    required this.tree,
    required this.fenMap,
    required this.pool,
    required this.evalResolver,
    required this.stats,
    required this.runLog,
    required this.progress,
    required this.onProgress,
    required this.cancel,
    required this.finishNow,
    required this.waitIfPaused,
    required this.nextNodeId,
  });

  bool get isCancelled => cancel.isCancelled;

  void log(String msg) => runLog.add('[TreeBuild] $msg');

  /// Create, register, and index a child of [parent], or return null when a
  /// sibling already covers [fen] (castling-representation dedup).
  BuildTreeNode? makeChild({
    required BuildTreeNode parent,
    required String fen,
    required String san,
    required String uci,
  }) {
    if (parent.children.any((c) => c.fen == fen)) return null;

    final child = BuildTreeNode(
      fen: fen,
      moveSan: san,
      moveUci: uci,
      ply: parent.ply + 1,
      isWhiteToMove: isWhiteToMove(fen),
      nodeId: nextNodeId++,
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

  /// Throttled progress emission anchored at [node].
  void emitNodeProgress(BuildTreeNode node) {
    progress.emitProgress(
      tree,
      node.ply,
      node.fen,
      onProgress,
      config.maxPly,
      buildSw: stopwatch,
    );
  }
}

/// Highest node id in [node]'s subtree — resume seeds the id allocator past
/// every id the loaded tree already uses.
int findMaxNodeId(BuildTreeNode node) {
  int maxId = node.nodeId;
  for (final child in node.children) {
    final childMax = findMaxNodeId(child);
    if (childMax > maxId) maxId = childMax;
  }
  return maxId;
}
