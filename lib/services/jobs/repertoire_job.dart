/// Background job abstraction for generation and audit tasks.
///
/// Jobs report progress via streams and can be paused/resumed/cancelled.
/// The [JobManager] tracks all active and completed jobs.
library;

import 'package:flutter/foundation.dart';

import '../../utils/safe_change_notifier.dart';

// ── Job status ──────────────────────────────────────────────────────

enum JobStatus { queued, running, paused, completed, cancelled, failed }

enum JobType {
  generation,
  audit,
  coverage,
  studyImport,
  tacticsImport,
  gameAnalysis,
  masterGames,
}

// ── Progress snapshot ───────────────────────────────────────────────

class JobProgress {
  final double fraction;
  final String message;
  final int nodesProcessed;
  final int totalNodes;

  const JobProgress({
    this.fraction = 0,
    this.message = '',
    this.nodesProcessed = 0,
    this.totalNodes = 0,
  });

  static const zero = JobProgress();
}

// ── Job definition ──────────────────────────────────────────────────

class RepertoireJob extends ChangeNotifier with SafeChangeNotifier {
  final String id;
  final JobType type;
  final String label;
  final String? subtreeFen;
  final DateTime createdAt;

  /// Snapshot of the config used to start this job (e.g. AuditConfig.toMap()).
  Map<String, dynamic>? configSnapshot;

  /// Asks the owning controller to cancel this job. Set by owners whose
  /// cancel affordance lives outside the repertoire screen (e.g. the
  /// tactics import coordinator), so any jobs UI can offer Cancel without
  /// knowing the owner.
  VoidCallback? onCancel;

  /// Stopping this job parks it instead of throwing its work away: everything
  /// it finished is already persisted, and starting it again carries on from
  /// there rather than repeating it (the games review works this way — each
  /// reviewed game files its counts as it completes). Jobs UI offers **Pause**
  /// rather than Cancel for these, and reports a stopped one as paused —
  /// "Cancelled" would claim the work was lost.
  bool resumable = false;

  JobStatus _status = JobStatus.queued;
  JobProgress _progress = JobProgress.zero;
  String? _error;
  DateTime? _completedAt;

  RepertoireJob({
    required this.id,
    required this.type,
    required this.label,
    this.subtreeFen,
    this.configSnapshot,
  }) : createdAt = DateTime.now();

  JobStatus get status => _status;
  JobProgress get progress => _progress;
  String? get error => _error;
  DateTime? get completedAt => _completedAt;
  bool get isActive =>
      _status == JobStatus.running || _status == JobStatus.paused;

  void updateStatus(JobStatus s) {
    if (_status == s) return;
    _status = s;
    if (s == JobStatus.completed ||
        s == JobStatus.cancelled ||
        s == JobStatus.failed) {
      _completedAt = DateTime.now();
    }
    notifyListeners();
  }

  void updateProgress(JobProgress p) {
    _progress = p;
    notifyListeners();
  }

  void fail(String message) {
    _error = message;
    updateStatus(JobStatus.failed);
  }
}

// ── Job manager (singleton) ─────────────────────────────────────────

class JobManager extends ChangeNotifier with SafeChangeNotifier {
  JobManager._();
  static final instance = JobManager._();

  final List<RepertoireJob> _jobs = [];

  List<RepertoireJob> get jobs => List.unmodifiable(_jobs);
  List<RepertoireJob> get activeJobs => _jobs.where((j) => j.isActive).toList();
  List<RepertoireJob> get completedJobs =>
      _jobs.where((j) => !j.isActive && j.status != JobStatus.queued).toList();

  RepertoireJob? get currentGenerationJob => _jobs
      .where((j) => j.type == JobType.generation && j.isActive)
      .firstOrNull;

  RepertoireJob? get currentAuditJob =>
      _jobs.where((j) => j.type == JobType.audit && j.isActive).firstOrNull;

  RepertoireJob? get currentCoverageJob =>
      _jobs.where((j) => j.type == JobType.coverage && j.isActive).firstOrNull;

  RepertoireJob? get currentStudyImportJob => _jobs
      .where((j) => j.type == JobType.studyImport && j.isActive)
      .firstOrNull;

  RepertoireJob? get currentTacticsImportJob => _jobs
      .where((j) => j.type == JobType.tacticsImport && j.isActive)
      .firstOrNull;

  RepertoireJob? get currentGameAnalysisJob => _jobs
      .where((j) => j.type == JobType.gameAnalysis && j.isActive)
      .firstOrNull;

  RepertoireJob? get currentMasterGamesJob => _jobs
      .where((j) => j.type == JobType.masterGames && j.isActive)
      .firstOrNull;

  /// Create and register a new job. Returns the job for further configuration.
  RepertoireJob createJob({
    required JobType type,
    required String label,
    String? subtreeFen,
  }) {
    final job = RepertoireJob(
      id: '${type.name}_${DateTime.now().millisecondsSinceEpoch}',
      type: type,
      label: label,
      subtreeFen: subtreeFen,
    );
    _jobs.insert(0, job);
    job.addListener(_onJobChanged);
    notifyListeners();
    return job;
  }

  void removeJob(RepertoireJob job) {
    job.removeListener(_onJobChanged);
    _jobs.remove(job);
    notifyListeners();
  }

  void clearCompleted() {
    _jobs.removeWhere((j) {
      if (!j.isActive && j.status != JobStatus.queued) {
        j.removeListener(_onJobChanged);
        return true;
      }
      return false;
    });
    notifyListeners();
  }

  void _onJobChanged() => notifyListeners();

  /// Summary string for the status bar (e.g. "Gen: 73%" or "Audit: running").
  String? get statusSummary {
    final gen = currentGenerationJob;
    if (gen != null) {
      final pct = (gen.progress.fraction * 100).toStringAsFixed(0);
      return gen.status == JobStatus.paused ? 'Gen: paused' : 'Gen: $pct%';
    }
    final audit = currentAuditJob;
    if (audit != null) {
      return audit.status == JobStatus.paused ? 'Audit: paused' : 'Auditing...';
    }
    final coverage = currentCoverageJob;
    if (coverage != null) {
      final pct = (coverage.progress.fraction * 100).toStringAsFixed(0);
      return 'Coverage: $pct%';
    }
    final import = currentStudyImportJob;
    if (import != null) {
      final p = import.progress;
      return p.totalNodes == 0
          ? 'Import: running'
          : 'Import: ${p.nodesProcessed}/${p.totalNodes}';
    }
    final tactics = currentTacticsImportJob;
    if (tactics != null) {
      final p = tactics.progress;
      return p.totalNodes == 0
          ? 'Tactics: running'
          : 'Tactics: ${p.nodesProcessed}/${p.totalNodes} games';
    }
    final gameAnalysis = currentGameAnalysisJob;
    if (gameAnalysis != null) {
      final p = gameAnalysis.progress;
      return p.totalNodes == 0
          ? 'Review: analyzing'
          : 'Review: ${p.nodesProcessed}/${p.totalNodes} games';
    }
    final masters = currentMasterGamesJob;
    if (masters != null) {
      final p = masters.progress;
      return p.totalNodes == 0
          ? 'TWIC: checking'
          : 'TWIC: ${p.nodesProcessed}/${p.totalNodes} issues';
    }
    return null;
  }
}
