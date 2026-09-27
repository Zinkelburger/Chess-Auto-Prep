import '../features/studies/models/study_import_state.dart';
import '../features/studies/models/study_import_exception.dart';
import 'generated/app_localizations.dart';

String studyImportProgressLabel(
  AppLocalizations l,
  StudyImportProgress p,
  int total,
) => switch (p.stage) {
  StudyImportStage.idle => '',
  StudyImportStage.starting => l.studyImportStarting,
  StudyImportStage.cancelling => l.studyImportCancelling,
  StudyImportStage.fetching => l.studyImportFetching(p.game, total),
  StudyImportStage.waiting => l.studyImportWaiting(
    p.game,
    p.remainingSeconds,
    total,
  ),
  StudyImportStage.retrying => l.studyImportRetrying(
    p.game,
    p.remainingSeconds,
    total,
  ),
  StudyImportStage.downloaded => l.studyImportDownloaded(p.downloaded),
  StudyImportStage.skipped => l.studyImportSkipped(p.gameId),
};

String studyImportFailureLabel(AppLocalizations l, StudyImportFailure f) =>
    switch (f) {
      StudyImportFailure.unresolvedPublication => l.studyImportUnresolved,
      StudyImportFailure.closed => l.studyImportClosed,
      StudyImportFailure.alreadyRunning => l.studyImportAlreadyRunning,
      StudyImportFailure.emptyCollection => l.studyImportEmpty,
      StudyImportFailure.invalidGameIds => l.studyImportInvalidIds,
      StudyImportFailure.startup => l.studyImportStartupFailed,
      StudyImportFailure.download => l.studyImportDownloadFailed,
      StudyImportFailure.throttled => l.studyImportThrottled,
      StudyImportFailure.publication => l.studyImportPublicationFailed,
      StudyImportFailure.uncertainPublication =>
        l.studyImportPublicationUncertain,
      StudyImportFailure.nameCollisions => l.studyImportNameCollisions,
    };

String studySourceFailureLabel(AppLocalizations l, StudyImportException e) =>
    switch (e.failure) {
      StudySourceFailure.offline => l.studyImportLichessOffline,
      StudySourceFailure.loginRequired => l.studyImportLichessLogin,
      StudySourceFailure.scopeRequired => l.studyImportLichessScope,
      StudySourceFailure.rejected => l.studyImportLichessRejected,
      StudySourceFailure.userMissing => l.studyImportLichessUserMissing(
        e.username!,
      ),
      StudySourceFailure.http => l.studyImportLichessHttp(e.statusCode!),
      StudySourceFailure.empty => l.studyImportLichessEmpty,
    };
