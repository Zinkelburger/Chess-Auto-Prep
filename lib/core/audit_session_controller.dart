/// Session controller for repertoire audits.
///
/// Owns the [RepertoireAuditService] and observable audit state so that
/// pause/resume/cancel/progress work from any widget. Handles persistence
/// of partial and complete audit results.
library;

import 'package:flutter/foundation.dart';

import '../features/audit/models/audit_finding.dart';
import '../features/audit/models/audit_result.dart';
import '../features/audit/services/audit_config.dart';
import '../features/audit/services/audit_persistence.dart';
import '../features/audit/services/repertoire_audit_service.dart';
import '../models/opening_tree.dart';
import '../services/engine/engine_lifecycle.dart';
import '../services/engine/stockfish_pool.dart';
import '../services/jobs/repertoire_job.dart';

class AuditSessionController extends ChangeNotifier {
  final RepertoireAuditService _service = RepertoireAuditService();

  AuditResult? _result;
  List<AuditFinding> _liveFindings = [];
  int _nodesChecked = 0;
  int _totalNodes = 0;
  AuditConfig? _lastConfig;
  bool _isAuditing = false;
  bool _isPaused = false;
  AuditSnapshot? _interruptedSnapshot;
  RepertoireJob? currentJob;

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
      _result != null || _liveFindings.isNotEmpty || _interruptedSnapshot != null;

  int get activeFindingCount =>
      _result?.activeFindingCount ?? _liveFindings.length;

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

  void cancel(String? repertoireFilePath) {
    if (!_isAuditing) return;
    _service.cancel();
    saveProgress(repertoireFilePath);
    currentJob?.updateStatus(JobStatus.cancelled);
    currentJob = null;
    EngineLifecycle().exitGeneration();
    _isAuditing = false;
    _isPaused = false;
    notifyListeners();
  }

  // ── Persistence ─────────────────────────────────────────────────────

  void saveProgress(String? repertoireFilePath) {
    final config = _lastConfig;
    if (config == null) return;
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
    );
    AuditPersistence.instance.saveProgress(
      repertoireFilePath,
      partialResult,
      config,
      _service.checkedFens,
    );
  }

  Future<void> tryRestore(String? repertoireId) async {
    final snapshot = await AuditPersistence.instance.load(repertoireId);
    if (snapshot == null) return;
    _result = snapshot.result;
    _lastConfig = snapshot.config;
    _liveFindings = [];
    _nodesChecked = snapshot.result.nodesChecked;
    _totalNodes = snapshot.result.nodesChecked;
    _interruptedSnapshot = snapshot.isComplete ? null : snapshot;
    debugPrint('[AuditController] Restored: '
        '${snapshot.result.findings.length} findings, '
        'isComplete=${snapshot.isComplete}');
    notifyListeners();
  }

  // ── Audit launch ────────────────────────────────────────────────────

  void onConfigChanged(AuditConfig config) {
    _lastConfig = config;
  }

  void onAuditingChanged(bool auditing, JobManager jobManager, String? label) {
    if (auditing && currentJob == null) {
      currentJob = jobManager.createJob(
        type: JobType.audit,
        label: label ?? 'Audit',
      );
      currentJob!.configSnapshot = _lastConfig?.toMap();
      currentJob!.updateStatus(JobStatus.running);
      _liveFindings = [];
      _result = null;
      _nodesChecked = 0;
      _totalNodes = 0;
      _isPaused = false;
    } else if (!auditing && currentJob != null) {
      currentJob!.updateStatus(JobStatus.completed);
      currentJob = null;
    }
    _isAuditing = auditing;
    notifyListeners();
  }

  void onResultReady(AuditResult auditResult, String? repertoireFilePath) {
    _result = auditResult;
    _liveFindings = [];
    if (_lastConfig != null) {
      AuditPersistence.instance.saveComplete(
        repertoireFilePath,
        auditResult,
        _lastConfig!,
      );
    }
    notifyListeners();
  }

  void onResultChanged(AuditResult updatedResult, String? repertoireFilePath) {
    _result = updatedResult;
    AuditPersistence.instance.saveResult(
      repertoireFilePath,
      updatedResult,
      config: _lastConfig,
    );
    notifyListeners();
  }

  void onLiveFinding(AuditFinding finding) {
    _liveFindings = [..._liveFindings, finding];
    notifyListeners();
  }

  void onProgress(int checked, int total) {
    _nodesChecked = checked;
    _totalNodes = total;
    currentJob?.updateProgress(JobProgress(
      fraction: total > 0 ? checked / total : 0,
      message: '$checked / $total positions',
      nodesProcessed: checked,
      totalNodes: total,
    ));
    notifyListeners();
  }

  // ── Resume interrupted audit ────────────────────────────────────────

  void clearInterrupted() {
    _interruptedSnapshot = null;
    notifyListeners();
  }

  void startFresh() {
    _interruptedSnapshot = null;
    _result = null;
    _liveFindings = [];
    _nodesChecked = 0;
    _totalNodes = 0;
    notifyListeners();
  }

  Future<void> launchResume({
    required AuditSnapshot snapshot,
    required OpeningTree tree,
    required bool isWhiteRepertoire,
    required JobManager jobManager,
    required String? repertoireLabel,
    required String? repertoireFilePath,
  }) async {
    final config = snapshot.config;
    _lastConfig = config;
    _liveFindings = [];
    _result = null;
    _nodesChecked = 0;
    _totalNodes = 0;
    _isPaused = false;
    _isAuditing = true;
    _interruptedSnapshot = null;

    currentJob = jobManager.createJob(
      type: JobType.audit,
      label: '${repertoireLabel ?? 'Audit'} (resumed)',
    );
    currentJob!.updateStatus(JobStatus.running);
    notifyListeners();

    if (config.useStockfish) {
      await EngineLifecycle().enterGeneration(1);
      await StockfishPool().ensureWorkers(1);
    }
    try {
      final auditResult = await _service.audit(
        tree: tree,
        isWhiteRepertoire: isWhiteRepertoire,
        config: config,
        skipFens: snapshot.checkedFens,
        priorFindings: snapshot.result.findings,
        onProgress: (p) {
          _nodesChecked = p.nodesChecked;
          _totalNodes = p.totalNodes;
          notifyListeners();
        },
        onFinding: (f) {
          _liveFindings = [..._liveFindings, f];
          notifyListeners();
        },
      );

      _result = auditResult;
      _liveFindings = [];
      _isAuditing = false;
      currentJob?.updateStatus(JobStatus.completed);
      currentJob = null;
      AuditPersistence.instance.saveComplete(
        repertoireFilePath, auditResult, config);
      notifyListeners();
    } catch (e) {
      _isAuditing = false;
      currentJob?.updateStatus(JobStatus.failed);
      currentJob = null;
      notifyListeners();
    } finally {
      if (config.useStockfish) EngineLifecycle().exitGeneration();
    }
  }

  void clearAll() {
    _result = null;
    _liveFindings = [];
    _nodesChecked = 0;
    _totalNodes = 0;
    _lastConfig = null;
    _interruptedSnapshot = null;
    notifyListeners();
  }
}
