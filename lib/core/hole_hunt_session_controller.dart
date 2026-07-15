/// Session controller for hole hunts (adversarial repertoire attacks).
///
/// Owns the [HoleHuntService] and observable hunt state so that
/// pause/resume/cancel/progress work from any widget. Handles persistence
/// of complete (and cancelled-partial) reports. Mirrors
/// [AuditSessionController] but without walk-resume support: v1 hunts are
/// cheap enough to re-run from scratch.
library;

import 'package:flutter/foundation.dart';

import '../features/audit/models/audit_finding.dart';
import '../features/audit/models/audit_result.dart';
import '../features/holes/services/hole_hunt_config.dart';
import '../features/holes/services/hole_hunt_persistence.dart';
import '../features/holes/services/hole_hunt_service.dart';
import '../services/engine/engine_lifecycle.dart';
import '../services/jobs/repertoire_job.dart';

class HoleHuntSessionController extends ChangeNotifier {
  final HoleHuntService _service = HoleHuntService();

  AuditResult? _result;
  List<AuditFinding> _liveFindings = [];
  HoleHuntProgress? _progress;
  HoleHuntConfig? _lastConfig;
  bool _isHunting = false;
  bool _isPaused = false;
  bool _trapPassSkipped = false;
  RepertoireJob? currentJob;

  /// Tracks which repertoire the current in-memory state belongs to.
  String? _activeRepertoireId;

  AuditResult? get result => _result;
  List<AuditFinding> get liveFindings => List.unmodifiable(_liveFindings);
  HoleHuntProgress? get progress => _progress;
  HoleHuntConfig? get lastConfig => _lastConfig;
  bool get isHunting => _isHunting;
  bool get isPaused => _isPaused;

  /// True when the last hunt skipped the practical-trap pass because Maia
  /// was unavailable.
  bool get trapPassSkipped => _trapPassSkipped;

  HoleHuntService get service => _service;

  bool get hasResults => _result != null || _liveFindings.isNotEmpty;

  int get activeFindingCount =>
      _result?.activeFindingCount ?? _liveFindings.length;

  String? get activeRepertoireId => _activeRepertoireId;

  // ── Repertoire switch ─────────────────────────────────────────────────

  /// Call before loading a new repertoire. Cancels an in-flight hunt
  /// (saving partial findings to the OLD repertoire path) and clears all
  /// in-memory state immediately.
  void onRepertoireSwitching(String? oldRepertoireFilePath) {
    if (_isHunting) {
      _service.cancel();
      _savePartial(oldRepertoireFilePath);
      currentJob?.updateStatus(JobStatus.cancelled);
      currentJob = null;
      EngineLifecycle.instance.exitGeneration();
      _isHunting = false;
      _isPaused = false;
    }
    _result = null;
    _liveFindings = [];
    _progress = null;
    _trapPassSkipped = false;
    _activeRepertoireId = null;
    notifyListeners();
  }

  // ── Control methods ───────────────────────────────────────────────────

  void pause() {
    if (!_isHunting || _isPaused) return;
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
    if (!_isHunting) return;
    _service.cancel();
    _savePartial(repertoireFilePath);
    currentJob?.updateStatus(JobStatus.cancelled);
    currentJob = null;
    EngineLifecycle.instance.exitGeneration();
    _isHunting = false;
    _isPaused = false;
    notifyListeners();
  }

  // ── Persistence ───────────────────────────────────────────────────────

  void _savePartial(String? repertoireFilePath) {
    final config = _lastConfig;
    if (config == null) return;
    final allFindings = <AuditFinding>[
      ...(_result?.findings ?? <AuditFinding>[]),
      ..._liveFindings,
    ];
    if (allFindings.isEmpty) return;
    final partialResult = AuditResult(
      findings: allFindings,
      nodesChecked: _result?.nodesChecked ?? 0,
      ourMoveNodesChecked: _result?.ourMoveNodesChecked ?? 0,
      opponentNodesChecked: _result?.opponentNodesChecked ?? 0,
      leafNodesChecked: _result?.leafNodesChecked ?? 0,
      elapsed: _result?.elapsed ?? Duration.zero,
    );
    HoleHuntPersistence.instance.save(
      repertoireFilePath,
      partialResult,
      config,
      isComplete: false,
    );
  }

  Future<void> tryRestore(String? repertoireId) async {
    _activeRepertoireId = repertoireId;
    final snapshot = await HoleHuntPersistence.instance.load(repertoireId);

    // Guard: if the user switched repertoires during the async load, discard.
    if (_activeRepertoireId != repertoireId) return;

    if (snapshot == null) {
      _result = null;
      _liveFindings = [];
      _progress = null;
      notifyListeners();
      return;
    }
    _result = snapshot.result;
    _lastConfig = snapshot.config;
    _liveFindings = [];
    _progress = null;
    debugPrint('[HoleHuntController] Restored: '
        '${snapshot.result.findings.length} findings, '
        'isComplete=${snapshot.isComplete}');
    notifyListeners();
  }

  // ── Hunt launch callbacks (wired from the config panel) ───────────────

  void onConfigChanged(HoleHuntConfig config) {
    _lastConfig = config;
  }

  void onHuntingChanged(bool hunting, JobManager jobManager, String? label) {
    if (hunting && currentJob == null) {
      currentJob = jobManager.createJob(
        type: JobType.holeHunt,
        label: label ?? 'Find holes',
      );
      currentJob!.configSnapshot = _lastConfig?.toMap();
      currentJob!.updateStatus(JobStatus.running);
      _liveFindings = [];
      _result = null;
      _progress = null;
      _trapPassSkipped = false;
      _isPaused = false;
    } else if (!hunting && currentJob != null) {
      currentJob!.updateStatus(JobStatus.completed);
      currentJob = null;
    }
    _isHunting = hunting;
    notifyListeners();
  }

  void onResultReady(AuditResult huntResult, String? repertoireFilePath) {
    _result = huntResult;
    _liveFindings = [];
    _trapPassSkipped = _service.trapPassSkipped;
    if (_lastConfig != null) {
      HoleHuntPersistence.instance.save(
        repertoireFilePath,
        huntResult,
        _lastConfig!,
      );
    }
    notifyListeners();
  }

  /// Re-persist after dismissal edits from the report panel.
  void onResultChanged(AuditResult updatedResult, String? repertoireFilePath) {
    _result = updatedResult;
    HoleHuntPersistence.instance.saveResult(
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

  void onProgress(HoleHuntProgress progress) {
    _progress = progress;
    currentJob?.updateProgress(JobProgress(
      fraction: progress.fraction,
      message: progress.message,
      nodesProcessed: progress.nodesChecked,
      totalNodes: progress.totalNodes,
    ));
    notifyListeners();
  }

  void clearAll() {
    _result = null;
    _liveFindings = [];
    _progress = null;
    _lastConfig = null;
    _trapPassSkipped = false;
    notifyListeners();
  }
}
