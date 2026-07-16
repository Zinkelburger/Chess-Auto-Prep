part of 'generation_session_controller.dart';

/// Progress state and its notification plumbing (throttled notifies, the
/// elapsed-time ticker, and the Jobs-panel sync).  Split out of
/// [GenerationSessionController] by pure code motion; owns every observable
/// `progress*` field so the pipeline and snapshot code read it through the
/// shared instance.
mixin _GenerationProgress on ChangeNotifier {
  static const Duration _notifyThrottle = Duration(milliseconds: 100);
  static const Duration _elapsedTick = Duration(seconds: 1);

  // Progress state (owned by the pipeline, displayed by the Jobs panel).
  String progressStatus = '';
  GenerationPhase progressPhase = GenerationPhase.idle;
  TreeBuildConfig? activeConfig;
  int progressNodes = 0;
  int progressDepth = 0;
  int progressMaxPlyConfig = 20;
  int progressUnexploredAtDepth = 0;
  int progressTotalAtDepth = 0;
  int progressLines = 0;
  double? progressNodesPerMinute;
  double? progressEtaSec;
  int progressElapsedMs = 0;
  bool progressBestFirst = false;
  int progressFrontier = 0;
  double? progressPriorityFraction;
  int? progressRunEtaSec;
  List<int> progressDepthTotals = const [];
  List<int> progressDepthExplored = const [];

  Timer? _elapsedTicker;
  Timer? _notifyTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  // Shared run state owned by the controller.
  bool get _isGenerating;
  bool get _isPaused;
  Stopwatch get _pipelineSw;
  RepertoireJob? get currentJob;

  // ── Progress plumbing ────────────────────────────────────────────────

  void _handleBuildProgress(BuildProgress p) {
    // Overwrite even with null: the ETA is per depth layer, and a stale
    // value from the previous layer must not linger into the next one.
    progressEtaSec = p.etaDepthSeconds?.toDouble();
    progressBestFirst = p.bestFirst;
    progressFrontier = p.frontierSize;
    progressPriorityFraction = p.priorityProgress;
    progressRunEtaSec = p.etaRunSeconds;
    progressDepthTotals = p.depthTotals;
    progressDepthExplored = p.depthExplored;
    updateProgress(
      nodes: p.totalNodes,
      depth: p.currentDepth,
      maxPlyConfig: p.maxPlyConfig,
      unexploredAtDepth: p.unexploredAtDepth,
      totalAtDepth: p.totalAtDepth,
      nodesPerMinute: p.nodesPerMinute,
      elapsedMs: _pipelineSw.elapsedMilliseconds,
    );
  }

  void _setStatus(String status, GenerationPhase phase) {
    progressStatus = status;
    progressPhase = phase;
    _flushProgressNotify();
  }

  /// Update observable progress fields.  Listener notification is
  /// throttled: high-frequency build callbacks coalesce to at most one
  /// notify per [_notifyThrottle].
  void updateProgress({
    int? nodes,
    int? depth,
    int? maxPlyConfig,
    int? unexploredAtDepth,
    int? totalAtDepth,
    int? lines,
    double? nodesPerMinute,
    int? elapsedMs,
  }) {
    if (nodes != null) progressNodes = nodes;
    if (depth != null) progressDepth = depth;
    if (maxPlyConfig != null) progressMaxPlyConfig = maxPlyConfig;
    if (unexploredAtDepth != null) {
      progressUnexploredAtDepth = unexploredAtDepth;
    }
    if (totalAtDepth != null) progressTotalAtDepth = totalAtDepth;
    if (lines != null) progressLines = lines;
    if (nodesPerMinute != null) progressNodesPerMinute = nodesPerMinute;
    if (elapsedMs != null) progressElapsedMs = elapsedMs;
    _notifyThrottled();
  }

  void _notifyThrottled() {
    final since = DateTime.now().difference(_lastNotify);
    if (since >= _notifyThrottle) {
      _flushProgressNotify();
    } else {
      _notifyTimer ??= Timer(_notifyThrottle - since, _flushProgressNotify);
    }
  }

  void _flushProgressNotify() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _lastNotify = DateTime.now();
    _syncProgressToJob();
    notifyListeners();
  }

  void _syncProgressToJob() {
    final job = currentJob;
    if (job == null) return;
    final statsLine = buildGenerationStatsLine(
      phase: progressPhase,
      nodes: progressNodes,
      currentDepth: progressDepth,
      maxPlyConfig: progressMaxPlyConfig,
      unexploredAtDepth: progressUnexploredAtDepth,
      totalAtDepth: progressTotalAtDepth,
      nodesPerMinute: progressNodesPerMinute,
      etaDepthSec: progressEtaSec?.round(),
      linesExtracted: progressLines,
      bestFirst: progressBestFirst,
      frontierSize: progressFrontier,
      etaRunSec: progressRunEtaSec,
    );
    job.updateProgress(
      JobProgress(
        fraction:
            generationProgressFraction(
              phase: progressPhase,
              currentDepth: progressDepth,
              maxPlyConfig: progressMaxPlyConfig,
              unexploredAtDepth: progressUnexploredAtDepth,
              totalAtDepth: progressTotalAtDepth,
              bestFirst: progressBestFirst,
              priorityProgress: progressPriorityFraction,
            ) ??
            0,
        message: statsLine,
        nodesProcessed: progressNodes,
      ),
    );
  }

  void _startElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(_elapsedTick, (_) {
      if (!_isGenerating || _isPaused) return;
      updateProgress(elapsedMs: _pipelineSw.elapsedMilliseconds);
    });
  }

  void _stopElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
  }

  void _resetProgress() {
    progressStatus = '';
    progressPhase = GenerationPhase.idle;
    activeConfig = null;
    progressNodes = 0;
    progressDepth = 0;
    progressMaxPlyConfig = 20;
    progressUnexploredAtDepth = 0;
    progressTotalAtDepth = 0;
    progressLines = 0;
    progressNodesPerMinute = null;
    progressEtaSec = null;
    progressElapsedMs = 0;
    progressBestFirst = false;
    progressFrontier = 0;
    progressPriorityFraction = null;
    progressRunEtaSec = null;
    progressDepthTotals = const [];
    progressDepthExplored = const [];
  }
}
