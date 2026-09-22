import '../../repertoires/models/repertoire_metadata.dart';
import '../../documents/models/pgn_document.dart';

/// Managed names and file lifecycle. PGN content goes through PgnDocumentStore;
/// native directory/reference transactions remain an explicit adapter boundary.
abstract interface class StudyLibraryRepository {
  Future<List<RepertoireMetadata>> list();
  Future<String> pathForName(String name);
  Future<String> suggestNewPath(String name);
  Future<bool> exists(String path);
  Future<PgnSnapshot> rename(PgnSnapshot baseline, String destination);
  Future<void> delete(String path);
  Future<String?> retainRecovery(String name, String content);
}
