import '../features/studies/models/study_import_state.dart';
import '../l10n/generated/app_localizations.dart';
import '../l10n/study_import_labels.dart';
import '../features/studies/repositories/study_import_repository.dart';
import '../services/jobs/repertoire_job.dart';

class RepertoireStudyImportJobs implements StudyImportJobs {
  RepertoireStudyImportJobs(this.manager, this.labels);
  final AppLocalizations Function() labels;
  final JobManager manager;
  @override
  StudyImportJob start(String name) => _Job(
    manager.createJob(
      type: JobType.studyImport,
      label: labels().studyImportJob(name),
    )..updateStatus(JobStatus.running),
    labels,
  );
}

class _Job implements StudyImportJob {
  _Job(this.job, this.labels);
  final AppLocalizations Function() labels;
  final RepertoireJob job;
  @override
  void progress(int done, int total, StudyImportProgress progress) =>
      job.updateProgress(
        JobProgress(
          fraction: total == 0 ? 0 : done / total,
          message: studyImportProgressLabel(labels(), progress, total),
          nodesProcessed: done,
          totalNodes: total,
        ),
      );
  @override
  void finish({
    required int chapters,
    required int total,
    required bool cancelled,
    StudyImportFailure? failure,
  }) {
    if (failure != null) {
      job.fail(studyImportFailureLabel(labels(), failure));
      return;
    }
    job.updateProgress(
      JobProgress(
        fraction: 1,
        message: labels().studyImportChapters(chapters),
        nodesProcessed: chapters,
        totalNodes: total,
      ),
    );
    job.updateStatus(cancelled ? JobStatus.cancelled : JobStatus.completed);
  }
}
