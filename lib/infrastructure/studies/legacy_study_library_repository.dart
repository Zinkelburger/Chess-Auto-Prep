import 'package:path/path.dart' as p;
import '../../features/documents/models/pgn_document.dart';
import '../../features/documents/repositories/pgn_document_store.dart';
import '../../features/repertoires/models/repertoire_metadata.dart';
import '../../features/studies/repositories/study_library_repository.dart';
import '../../services/storage/storage_service.dart';
import '../../services/storage/study_naming.dart' show sanitizeStudyName;

class LegacyStudyLibraryRepository implements StudyLibraryRepository {
  LegacyStudyLibraryRepository(this.storage, this.documents);
  final StorageService storage;
  final PgnDocumentStore documents;
  @override
  Future<List<RepertoireMetadata>> list() => storage.listStudyFiles();
  @override
  Future<String> pathForName(String name) =>
      storage.studyFilePath(sanitizeStudyName(name));
  @override
  Future<bool> exists(String path) => storage.fileExists(path);
  @override
  Future<String> suggestNewPath(String name) async {
    final base = sanitizeStudyName(name);
    var path = await pathForName(base);
    var suffix = 2;
    while (await exists(path)) {
      path = await pathForName('$base (${suffix++})');
    }
    return path;
  }

  @override
  Future<PgnSnapshot> rename(PgnSnapshot baseline, String destination) async {
    await storage.renameFile(baseline.path, destination);
    // Both current adapters bind documentId to the canonical path. A move
    // retains the captured identity/content, never adopts unseen external edits.
    final opened = await documents.open(destination);
    final path = opened is PgnOpened
        ? opened.snapshot.path
        : p.normalize(destination);
    return PgnSnapshot(
      path: path,
      content: baseline.content,
      revision: PgnRevision(
        documentId: path,
        nativeIdentity: baseline.revision.nativeIdentity,
        sha256: baseline.revision.sha256,
      ),
    );
  }

  @override
  Future<void> delete(String path) => storage.deleteFile(path);
  @override
  Future<String?> retainRecovery(String name, String content) async {
    try {
      final path = await suggestNewPath(
        'Recovered $name ${DateTime.now().microsecondsSinceEpoch}',
      );
      final result = await documents.create(path, content);
      return result is PgnSaved ? result.after.path : null;
    } catch (_) {
      return null;
    }
  }
}
