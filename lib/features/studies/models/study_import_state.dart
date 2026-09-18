import '../../documents/models/pgn_document.dart';

enum StudyImportStage {
  idle,
  starting,
  fetching,
  waiting,
  retrying,
  downloaded,
  skipped,
  cancelling,
}

enum StudyImportFailure {
  closed,
  unresolvedPublication,
  alreadyRunning,
  emptyCollection,
  invalidGameIds,
  startup,
  download,
  throttled,
  publication,
  uncertainPublication,
  nameCollisions,
}

class StudyImportRejected implements Exception {
  const StudyImportRejected(this.failure);
  final StudyImportFailure failure;
}

class StudyImportProgress {
  const StudyImportProgress(
    this.stage, {
    this.game = 0,
    this.downloaded = 0,
    this.remainingSeconds = 0,
    this.gameId = '',
  });
  final StudyImportStage stage;
  final int game;
  final int downloaded;
  final int remainingSeconds;
  final String gameId;
}

/// Exact attempted bytes and destination survive an unacknowledged write.
class StudyImportPublication {
  const StudyImportPublication({
    required this.path,
    required this.content,
    required this.outcome,
    this.failure,
  });
  final String path;
  final String content;
  final PgnWriteResult outcome;
  final StudyImportFailure? failure;
}
