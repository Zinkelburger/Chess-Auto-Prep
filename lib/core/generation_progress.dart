/// Observable progress of a generation run.
///
/// Owned by [GenerationSessionController]. The Jobs panel and lock overlay
/// read this object; the pipeline writes it. Notification is throttled so
/// high-frequency build callbacks do not rebuild the UI every node.
library;

import 'dart:async';

import '../chess_core/generation/build_tree_node.dart';
import '../services/jobs/generation_job_display.dart';
import '../services/jobs/repertoire_job.dart';
import '../services/jobs/notify_throttle.dart';

class GenerationProgress {
  GenerationProgress({required this._notify});

  // One cadence for ordinary job stats and Builder updates. Lifecycle edges
  // explicitly flush; phase/status bursts share the same four-updates/s budget.
  final void Function() _notify;
  final Stopwatch _elapsed = Stopwatch();
  late final NotifyThrottle _throttle = NotifyThrottle(
    _notify,
    interval: const Duration(milliseconds: 250),
  );
  Duration get elapsed => _elapsed.elapsed;
  bool _disposed = false;

  String status = '';
  GenerationPhase phase = GenerationPhase.idle;
  int nodes = 0;
  int depth = 0;
  int maxPlyConfig = 20;
  int unexploredAtDepth = 0;
  int totalAtDepth = 0;
  int lines = 0;
  double? nodesPerMinute;
  double? etaDepthSec;
  int elapsedMs = 0;
  bool bestFirst = false;
  int frontier = 0;
  double? priorityFraction;
  int? runEtaSec;
  List<int> depthTotals = const [];
  List<int> depthExplored = const [];

  Timer? _elapsedTicker;

  /// Copy live BFS stats from a build callback. Depth-layer ETA is overwritten
  /// even when null so a stale value from the previous layer cannot linger.
  void handleBuildProgress(BuildProgress p) {
    etaDepthSec = p.etaDepthSeconds?.toDouble();
    bestFirst = p.bestFirst;
    frontier = p.frontierSize;
    priorityFraction = p.priorityProgress;
    runEtaSec = p.etaRunSeconds;
    depthTotals = p.depthTotals;
    depthExplored = p.depthExplored;
    update(
      nodes: p.totalNodes,
      depth: p.currentDepth,
      maxPlyConfig: p.maxPlyConfig,
      unexploredAtDepth: p.unexploredAtDepth,
      totalAtDepth: p.totalAtDepth,
      nodesPerMinute: p.nodesPerMinute,
      elapsedMs: _elapsed.elapsedMilliseconds,
    );
  }

  void setStatus(String status, GenerationPhase phase) {
    this.status = status;
    this.phase = phase;
    if (!_disposed) _throttle();
  }

  /// Update observable fields. Listener notification is throttled: high-
  /// frequency build callbacks coalesce to at most one notify per
  /// the shared throttle.
  void update({
    int? nodes,
    int? depth,
    int? maxPlyConfig,
    int? unexploredAtDepth,
    int? totalAtDepth,
    int? lines,
    double? nodesPerMinute,
    int? elapsedMs,
  }) {
    if (nodes != null) this.nodes = nodes;
    if (depth != null) this.depth = depth;
    if (maxPlyConfig != null) this.maxPlyConfig = maxPlyConfig;
    if (unexploredAtDepth != null) this.unexploredAtDepth = unexploredAtDepth;
    if (totalAtDepth != null) this.totalAtDepth = totalAtDepth;
    if (lines != null) this.lines = lines;
    if (nodesPerMinute != null) this.nodesPerMinute = nodesPerMinute;
    if (elapsedMs != null) this.elapsedMs = elapsedMs;
    if (!_disposed) _throttle();
  }

  void flushNotify() {
    if (!_disposed) _throttle.flush();
  }

  JobProgress get jobProgress {
    final statsLine = buildGenerationStatsLine(
      phase: phase,
      nodes: nodes,
      currentDepth: depth,
      maxPlyConfig: maxPlyConfig,
      unexploredAtDepth: unexploredAtDepth,
      totalAtDepth: totalAtDepth,
      nodesPerMinute: nodesPerMinute,
      etaDepthSec: etaDepthSec?.round(),
      linesExtracted: lines,
      bestFirst: bestFirst,
      frontierSize: frontier,
      etaRunSec: runEtaSec,
    );
    return JobProgress(
      fraction:
          generationProgressFraction(
            phase: phase,
            currentDepth: depth,
            maxPlyConfig: maxPlyConfig,
            unexploredAtDepth: unexploredAtDepth,
            totalAtDepth: totalAtDepth,
            bestFirst: bestFirst,
            priorityProgress: priorityFraction,
          ) ??
          0,
      message: statsLine,
      nodesProcessed: nodes,
    );
  }

  void begin() {
    if (_disposed) return;
    reset();
    _elapsed
      ..reset()
      ..start();
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_elapsed.isRunning) update(elapsedMs: _elapsed.elapsedMilliseconds);
    });
  }

  void pause() => _elapsed.stop();
  void resume() {
    if (!_disposed) _elapsed.start();
  }

  void finish() {
    _elapsed.stop();
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
    _throttle.dispose();
    reset();
  }

  void reset() {
    status = '';
    phase = GenerationPhase.idle;
    nodes = 0;
    depth = 0;
    maxPlyConfig = 20;
    unexploredAtDepth = 0;
    totalAtDepth = 0;
    lines = 0;
    nodesPerMinute = null;
    etaDepthSec = null;
    elapsedMs = 0;
    bestFirst = false;
    frontier = 0;
    priorityFraction = null;
    runEtaSec = null;
    depthTotals = const [];
    depthExplored = const [];
  }

  void dispose() {
    _disposed = true;
    finish();
  }
}
