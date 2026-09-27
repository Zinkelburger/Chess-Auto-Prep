import '../models/study_import_state.dart';
import '../models/import_source.dart';

enum StudyGameFetchStatus { ok, throttled, failed }

typedef StudyGameFetch = ({StudyGameFetchStatus status, String? pgn});
typedef FetchedStudy = ({String pgn, String name});
typedef StudyCollectionSource = ({List<String> gameIds, String name});

/// One network session, closed by its dialog or background run owner.
abstract interface class StudyImportSource {
  Future<StudyGameFetch> fetchGame(String id);
  Future<FetchedStudy> fetchLichess(ImportSource source);
  Future<StudyCollectionSource> fetchCollection(String id);
  void close();
}

abstract interface class StudyImportRepository {
  StudyImportSource openSource();
  Future<String?> readCachedGame(String id);
  Future<void> cacheGame(String id, String pgn);

  /// Creates a unique destination atomically. Never replaces an existing study.
  Future<StudyImportPublication> publish(String name, String pgn);
}

abstract interface class StudyImportJobs {
  StudyImportJob start(String name);
}

abstract interface class StudyImportJob {
  void progress(int done, int total, StudyImportProgress progress);
  void finish({
    required int chapters,
    required int total,
    required bool cancelled,
    StudyImportFailure? failure,
  });
}
