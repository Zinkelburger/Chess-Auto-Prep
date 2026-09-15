/// The Jobs-pane entry for an evaluation-database download.
library;

import 'package:flutter/foundation.dart';

import '../jobs/repertoire_job.dart';

/// The job a (re)started download should report through.
///
/// A job that is still active — running, or parked by a pause — is reused
/// and marked running again, so pausing and resuming does not stack up
/// entries in the Jobs pane. Otherwise a fresh resumable job is created whose
/// cancel button calls [onCancel].
RepertoireJob ensureEvalDatabaseJob(
  RepertoireJob? existing, {
  required String label,
  required VoidCallback onCancel,
}) {
  if (existing != null && existing.isActive) {
    existing.updateStatus(JobStatus.running);
    return existing;
  }
  final job = JobManager.instance.createJob(
    type: JobType.evalDatabase,
    label: label,
  );
  job.resumable = true;
  job.onCancel = onCancel;
  job.updateStatus(JobStatus.running);
  return job;
}
