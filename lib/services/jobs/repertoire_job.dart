/// Background job abstraction for generation and audit tasks.
///
/// Jobs report progress through [ChangeNotifier] and can be paused, resumed
/// or cancelled. The [JobManager] tracks all active and completed jobs.
library;

import 'package:flutter/foundation.dart';

import '../../utils/safe_change_notifier.dart';

enum JobStatus {
  queued,
  running,
  paused,
  completed,
  cancelled,
  failed;

  /// Whether the job has reached a final state and will not run again.
  bool get isTerminal => switch (this) {
    completed || cancelled || failed => true,
    queued || running || paused => false,
  };
}

enum JobType {
  generation,
  audit,
  coverage,
  studyImport,
  tacticsImport,
  gameAnalysis,
  masterGames,
  evalDatabase,
}

/// A point-in-time progress report; [fraction] is 0–1.
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
    if (s.isTerminal) _completedAt = DateTime.now();
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

/// Registry of every job the app has started this session, newest first.
class JobManager extends ChangeNotifier with SafeChangeNotifier {
  JobManager();
  static final instance = JobManager();

  final List<RepertoireJob> _jobs = [];

  List<RepertoireJob> get jobs => List.unmodifiable(_jobs);
  List<RepertoireJob> get activeJobs => _jobs.where((j) => j.isActive).toList();
  List<RepertoireJob> get completedJobs =>
      _jobs.where((j) => j.status.isTerminal).toList();

  /// The newest running or paused job of [type], if any.
  RepertoireJob? activeJob(JobType type) =>
      _jobs.where((j) => j.type == type && j.isActive).firstOrNull;

  /// Create and register a new job. Returns the job for further configuration.
  RepertoireJob createJob({
    required JobType type,
    required String label,
    String? subtreeFen,
    Map<String, dynamic>? configSnapshot,
    JobStatus status = JobStatus.queued,
  }) {
    final job = RepertoireJob(
      id: '${type.name}_${DateTime.now().millisecondsSinceEpoch}',
      type: type,
      label: label,
      subtreeFen: subtreeFen,
      configSnapshot: configSnapshot,
    )..updateStatus(status);
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
      if (!j.status.isTerminal) return false;
      j.removeListener(_onJobChanged);
      return true;
    });
    notifyListeners();
  }

  void _onJobChanged() => notifyListeners();
}
