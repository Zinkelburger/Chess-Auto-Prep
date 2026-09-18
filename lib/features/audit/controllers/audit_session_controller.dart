/// Session controller for repertoire audits.
///
/// Owns the [RepertoireAuditService] and observable audit state so that
/// pause/resume/cancel/progress work from any widget. Handles persistence
/// of partial and complete audit results.
library;

import 'package:chess_auto_prep/chess_core/moves/opening_graph.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../services/jobs/notify_throttle.dart';
import '../../../services/jobs/repertoire_job.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/audit_finding.dart';
import '../models/audit_result.dart';
import '../services/audit_config.dart';
import '../services/audit_persistence.dart';
import '../services/repertoire_audit_service.dart';

class AuditSessionController extends ChangeNotifier with SafeChangeNotifier {
  AuditSessionController({
    required RepertoireAuditService service,
    required Future<void> Function() prepareEngine,
    required Future<void> Function() releaseEngine,
  }) : _service = service,
       _prepareEngine = prepareEngine,
       _releaseEngine = releaseEngine;

  final Future<void> Function() _prepareEngine;
  final Future<void> Function() _releaseEngine;
  Future<void>? _runTail;
  int _runVersion = 0;
  int get runVersion => _runVersion;
  String? _error;
  String? get error => _error;
  String? _startFen;
  String? get startFen => _startFen;
  int? _serviceVersion;
  Set<String> _resumeCheckedFens = const {};
  List<String> _resumeWarnings = const [];

  @override
  void dispose() {
    _runVersion++;
    _service.cancel();
    _progressNotify.dispose();
    super.dispose();
  }

  final RepertoireAuditService _service;

  AuditResult? _resultValue;

  /// Every write to the result goes through here so [resultVersion] cannot
  /// fall behind it.
  AuditResult? get _result => _resultValue;
  set _result(AuditResult? value) {
    _resultValue = value;
    _resultVersion++;
  }

  /// Bumped whenever the result is replaced *or edited in place*.
  ///
  /// Views that cache work derived from the findings cannot key that cache on
  /// the result's identity: dismissing a finding mutates `dismissed` on the
  /// existing [AuditFinding] and hands the very same [AuditResult] back, so
  /// the object never changes even though what it means to a board or a
  /// summary just did.
  int get resultVersion => _resultVersion;
  int _resultVersion = 0;

  List<AuditFinding> _liveFindings = [];
  int _nodesChecked = 0;
  int _totalNodes = 0;
  AuditConfig? _lastConfig;
  bool _isAuditing = false;
  bool _isPaused = false;
  AuditSnapshot? _interruptedSnapshot;
  RepertoireJob? currentJob;

  /// Tracks which repertoire the current in-memory state belongs to.
  String? _activeRepertoireId;

  AuditResult? get result => _result;
  List<AuditFinding> get liveFindings => List.unmodifiable(_liveFindings);
  int get nodesChecked => _nodesChecked;
  int get totalNodes => _totalNodes;
  AuditConfig? get lastConfig => _lastConfig;
  bool get isAuditing => _isAuditing;
  bool get isPaused => _isPaused;
  AuditSnapshot? get interruptedSnapshot => _interruptedSnapshot;

  RepertoireAuditService get service => _service;

  bool get hasResults =>
      _result != null ||
      _liveFindings.isNotEmpty ||
      _interruptedSnapshot != null;

  int get activeFindingCount =>
      _result?.activeFindingCount ?? _liveFindings.length;

  String? get activeRepertoireId => _activeRepertoireId;

  // ── Repertoire switch ─────────────────────────────────────────────────

  /// Call before loading a new repertoire. Saves in-flight progress to the
  /// OLD repertoire path and clears all in-memory audit state immediately.
  void onRepertoireSwitching(String? oldRepertoireFilePath) {
    _error = null;
    if (_isAuditing) {
      _service.cancel();
      saveProgress(oldRepertoireFilePath);
      currentJob?.updateStatus(JobStatus.cancelled);
      currentJob = null;
      _isAuditing = false;
      _isPaused = false;
    }
    _runVersion++;
    _clearRunState();
    _activeRepertoireId = null;
    notifyListeners();
  }

  // ── Control methods ─────────────────────────────────────────────────

  void pause() {
    if (!_isAuditing || _isPaused) return;
    _service.pause();
    _isPaused = true;
    currentJob?.updateStatus(JobStatus.paused);
    notifyListeners();
  }

  void resume() {
    if (!_isPaused) return;
    _service.resume();
    _isPaused = false;
    currentJob?.updateStatus(JobStatus.running);
    notifyListeners();
  }

  void cancel() {
    if (!_isAuditing) return;
    _service.cancel();
    saveProgress(_activeRepertoireId);
    _runVersion++;
    currentJob?.updateStatus(JobStatus.cancelled);
    currentJob = null;
    _isAuditing = false;
    _isPaused = false;
    notifyListeners();
  }

  // ── Persistence ─────────────────────────────────────────────────────

  void saveProgress(String? repertoireFilePath) {
    final config = _lastConfig;
    if (config == null) return;
    final checkedFens = _serviceVersion == _runVersion
        ? _service.checkedFens
        : _resumeCheckedFens;
    final allFindings = <AuditFinding>[
      ...(_result?.findings ?? <AuditFinding>[]),
      ..._liveFindings,
    ];
    final partialResult = AuditResult(
      findings: allFindings,
      nodesChecked: _nodesChecked,
      ourMoveNodesChecked: _result?.ourMoveNodesChecked ?? 0,
      opponentNodesChecked: _result?.opponentNodesChecked ?? 0,
      leafNodesChecked: _result?.leafNodesChecked ?? 0,
      elapsed: _result?.elapsed ?? Duration.zero,
      warnings: _serviceVersion == _runVersion
          ? _service.warnings
          : (_result?.warnings ?? _resumeWarnings),
    );
    _interruptedSnapshot = AuditSnapshot(
      result: partialResult,
      config: config,
      checkedFens: checkedFens,
      startFen: _startFen,
      isComplete: false,
    );
    unawaited(
      AuditPersistence.instance.saveProgress(
        repertoireFilePath,
        partialResult,
        config,
        checkedFens,
        startFen: _startFen,
      ),
    );
  }

  Future<void> tryRestore(String? repertoireId) async {
    _activeRepertoireId = repertoireId;
    final version = _runVersion;
    final snapshot = await AuditPersistence.instance.load(repertoireId);

    // Guard: if the user switched repertoires during the async load, discard.
    if (isDisposed ||
        _activeRepertoireId != repertoireId ||
        version != _runVersion) {
      return;
    }

    if (snapshot == null) {
      _clearRunState();
      notifyListeners();
      return;
    }
    _result = snapshot.result;
    _lastConfig = snapshot.config;
    _startFen = snapshot.startFen;
    _liveFindings = [];
    _nodesChecked = snapshot.result.nodesChecked;
    _totalNodes = snapshot.result.nodesChecked;
    _interruptedSnapshot = snapshot.isComplete ? null : snapshot;
    debugPrint(
      '[AuditController] Restored: '
      '${snapshot.result.findings.length} findings, '
      'isComplete=${snapshot.isComplete}',
    );
    notifyListeners();
  }

  // ── Audit launch ────────────────────────────────────────────────────

  void onConfigChanged(AuditConfig config) {
    _lastConfig = config;
  }

  void onAuditingChanged(bool auditing, JobManager jobManager, String? label) {
    final job = currentJob;
    if (auditing && job == null) {
      _runVersion++;
      _error = null;
      currentJob =
          jobManager.createJob(type: JobType.audit, label: label ?? 'Audit')
            ..configSnapshot = _lastConfig?.toMap()
            ..updateStatus(JobStatus.running);
      _clearRunState();
      _isPaused = false;
    } else if (!auditing && job != null) {
      job.updateStatus(JobStatus.completed);
      currentJob = null;
    }
    _isAuditing = auditing;
    notifyListeners();
  }

  void onResultReady(
    AuditResult auditResult,
    String? repertoireFilePath, {
    int? runVersion,
  }) {
    if (runVersion != null && runVersion != _runVersion) return;
    _result = auditResult;
    _liveFindings = [];
    if (_lastConfig case final config?) {
      unawaited(
        AuditPersistence.instance.saveComplete(
          repertoireFilePath,
          auditResult,
          config,
          startFen: _startFen,
        ),
      );
    }
    notifyListeners();
  }

  void onResultChanged(AuditResult updatedResult, String? repertoireFilePath) {
    _result = updatedResult;
    final interrupted = _interruptedSnapshot;
    if (interrupted != null) {
      _interruptedSnapshot = AuditSnapshot(
        result: updatedResult,
        config: interrupted.config,
        checkedFens: interrupted.checkedFens,
        startFen: interrupted.startFen,
        isComplete: false,
      );
    }
    unawaited(
      AuditPersistence.instance.saveResult(
        repertoireFilePath,
        updatedResult,
        config: _lastConfig,
      ),
    );
    notifyListeners();
  }

  /// Live findings and progress arrive per position; the screen only needs
  /// to hear about them a few times a second.
  late final NotifyThrottle _progressNotify = NotifyThrottle(notifyListeners);

  void onLiveFinding(AuditFinding finding) {
    _liveFindings = [..._liveFindings, finding];
    _progressNotify();
  }

  void onProgress(int checked, int total) {
    _nodesChecked = checked;
    _totalNodes = total;
    currentJob?.updateProgress(
      JobProgress(
        fraction: total > 0 ? checked / total : 0,
        message: '$checked / $total positions',
        nodesProcessed: checked,
        totalNodes: total,
      ),
    );
    _progressNotify();
  }

  // ── Resume interrupted audit ────────────────────────────────────────

  void clearInterrupted() {
    _interruptedSnapshot = null;
    notifyListeners();
  }

  void startFresh() {
    _clearRunState();
    notifyListeners();
  }

  /// The controller owns the run after its configuration route closes.
  /// Runs are serialized so a cancelled engine call must finish before a new
  /// audit resets the shared service or acquires the engine pool.
  Future<void> launch({
    required AuditConfig config,
    required OpeningGraph tree,
    required bool isWhiteRepertoire,
    required JobManager jobManager,
    required String? repertoireLabel,
    required String? repertoireFilePath,
    String? startFen,
    AuditSnapshot? resumeSnapshot,
  }) {
    if (_isAuditing) return _runTail ?? Future.value();
    _lastConfig = config;
    _startFen = startFen;
    _resumeCheckedFens = resumeSnapshot?.checkedFens ?? const {};
    _resumeWarnings = resumeSnapshot?.result.warnings ?? const [];
    _activeRepertoireId = repertoireFilePath;
    onAuditingChanged(true, jobManager, repertoireLabel);
    if (resumeSnapshot != null) {
      _liveFindings = [...resumeSnapshot.result.findings];
    }
    final version = _runVersion;
    final previous = _runTail;
    // [onAuditingChanged] has just created the job for this run.
    final job = currentJob!;
    final run = _execute(
      previous: previous,
      version: version,
      job: job,
      config: config,
      tree: tree,
      isWhiteRepertoire: isWhiteRepertoire,
      repertoireFilePath: repertoireFilePath,
      startFen: startFen,
      resumeSnapshot: resumeSnapshot,
    );
    _runTail = run;
    return run;
  }

  Future<void> _execute({
    required Future<void>? previous,
    required int version,
    required RepertoireJob job,
    required AuditConfig config,
    required OpeningGraph tree,
    required bool isWhiteRepertoire,
    required String? repertoireFilePath,
    required String? startFen,
    required AuditSnapshot? resumeSnapshot,
  }) async {
    bool current() => !isDisposed && version == _runVersion;
    var engineOwned = false;
    try {
      await previous;
      if (!current()) return;
      if (config.useStockfish) {
        engineOwned = true;
        await _prepareEngine();
      }
      if (!current()) return;
      _serviceVersion = version;
      final resultFuture = _service.audit(
        tree: tree,
        isWhiteRepertoire: isWhiteRepertoire,
        config: config,
        startFen: startFen,
        skipFens: resumeSnapshot?.checkedFens ?? const {},
        priorFindings: resumeSnapshot?.result.findings ?? const [],
        priorWarnings: _resumeWarnings,
        onProgress: (progress) {
          if (current()) onProgress(progress.nodesChecked, progress.totalNodes);
        },
        onFinding: (finding) {
          if (current()) onLiveFinding(finding);
        },
      );
      if (_isPaused) _service.pause();
      final result = await resultFuture;
      if (!current()) return;
      onResultReady(result, repertoireFilePath, runVersion: version);
      job.updateStatus(JobStatus.completed);
    } catch (e) {
      if (!current()) return;
      _error = 'Audit could not finish. $e';
      saveProgress(repertoireFilePath);
      job.updateStatus(JobStatus.failed);
    } finally {
      try {
        if (engineOwned) await _releaseEngine();
      } catch (e) {
        if (current()) _error = 'Could not release the audit engine. $e';
      }
      if (current()) {
        _isAuditing = false;
        _isPaused = false;
        currentJob = null;
        notifyListeners();
      }
    }
  }

  Future<void> launchResume({
    required AuditSnapshot snapshot,
    required OpeningGraph tree,
    required bool isWhiteRepertoire,
    required JobManager jobManager,
    required String? repertoireLabel,
    required String? repertoireFilePath,
  }) => launch(
    config: snapshot.config,
    tree: tree,
    isWhiteRepertoire: isWhiteRepertoire,
    jobManager: jobManager,
    repertoireLabel: '${repertoireLabel ?? 'Audit'} (resumed)',
    repertoireFilePath: repertoireFilePath,
    startFen: snapshot.startFen,
    resumeSnapshot: snapshot,
  );

  void clearAll() {
    _runVersion++;
    _error = null;
    _clearRunState();
    _lastConfig = null;
    notifyListeners();
  }

  /// Forget the result, live findings, progress and any interrupted
  /// snapshot. Callers notify.
  void _clearRunState() {
    _result = null;
    _liveFindings = [];
    _nodesChecked = 0;
    _totalNodes = 0;
    _interruptedSnapshot = null;
  }
}
