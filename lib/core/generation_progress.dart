/// Observable progress of a generation run.
///
/// Owned by [GenerationSessionController]. The Jobs panel and lock overlay
/// read this object; the pipeline writes it. Notification is throttled so
/// high-frequency build callbacks do not rebuild the UI every node.
library;

import 'dart:async';

import '../models/build_tree_node.dart';
import '../services/jobs/generation_job_display.dart';
import '../services/jobs/repertoire_job.dart';

export '../services/jobs/generation_phase.dart' show GenerationPhase;

class GenerationProgress {
  GenerationProgress({
    required this._notify,
    required this._job,
    required this._isRunning,
    required this._isPaused,
    required this._elapsed,
  });

  static const Duration _notifyThrottle = Duration(milliseconds: 100);
  static const Duration _elapsedTick = Duration(seconds: 1);

  final void Function() _notify;
  final RepertoireJob? Function() _job;
  final bool Function() _isRunning;
  final bool Function() _isPaused;
  final Stopwatch Function() _elapsed;

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
  Timer? _notifyTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

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
      elapsedMs: _elapsed().elapsedMilliseconds,
    );
  }

  void setStatus(String status, GenerationPhase phase) {
    this.status = status;
    this.phase = phase;
    flushNotify();
  }

  /// Update observable fields. Listener notification is throttled: high-
  /// frequency build callbacks coalesce to at most one notify per
  /// [_notifyThrottle].
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
    _notifyThrottled();
  }

  void _notifyThrottled() {
    final since = DateTime.now().difference(_lastNotify);
    if (since >= _notifyThrottle) {
      flushNotify();
    } else {
      _notifyTimer ??= Timer(_notifyThrottle - since, flushNotify);
    }
  }

  void flushNotify() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _lastNotify = DateTime.now();
    _syncToJob();
    _notify();
  }

  void _syncToJob() {
    final job = _job();
    if (job == null) return;
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
    job.updateProgress(
      JobProgress(
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
      ),
    );
  }

  void startElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(_elapsedTick, (_) {
      if (!_isRunning() || _isPaused()) return;
      update(elapsedMs: _elapsed().elapsedMilliseconds);
    });
  }

  void stopElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
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
    _notifyTimer?.cancel();
    _notifyTimer = null;
    stopElapsedTicker();
  }
}
