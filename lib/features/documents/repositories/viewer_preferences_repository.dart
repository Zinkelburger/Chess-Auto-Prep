import '../../../models/pgn_filter_models.dart';
import '../models/viewer_session.dart';

/// Reading preferences, separate from PGN document contents and recovery.
/// Implementations preserve ordering between writes and subsequent reads.
abstract interface class ViewerPreferencesRepository {
  Future<String?> lastFile();
  Future<ViewerSession?> loadSession(String path);
  Future<void> saveSession(String path, ViewerSession session);
  Future<void> closeSession();
  Future<List<String>> loadRecentFiles();
  Future<void> saveRecentFiles(List<String> paths);
  Future<SliceConfig?> loadSlice(String path);
  Future<void> saveSlice(String path, SliceConfig config);
  Future<bool> autoDetectOpenings();
}
