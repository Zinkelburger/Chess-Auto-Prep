import '../../features/repertoires/models/repertoire_creation.dart';
import '../../features/repertoires/models/repertoire_metadata.dart';
import '../../features/repertoires/repositories/repertoire_catalog_repository.dart';
import '../../services/repertoire_creation.dart';
import '../../services/storage/storage_service.dart';
import '../../utils/safe_file_name.dart';

/// Temporary adapter to existing format/migration owners. Remove when the
/// document store and recoverable directory transactions replace StorageService
/// in renewal milestones 2/3. All dependencies are supplied by app startup.
class LegacyRepertoireCatalogRepository implements RepertoireCatalogRepository {
  LegacyRepertoireCatalogRepository(this._storage);

  final StorageService _storage;

  @override
  Future<List<RepertoireMetadata>> listRepertoires() =>
      _storage.listRepertoires();

  @override
  Future<List<RepertoireMetadata>> listStudies() => _storage.listStudyFiles();

  @override
  Future<RepertoireCreationResult> create(CreateRepertoire request) async {
    requireSafeFileName(request.name);
    if (request.color != 'White' && request.color != 'Black') {
      throw ArgumentError.value(request.color, 'color');
    }
    final existing = await _storage.listRepertoires();
    if (existing.any(
      (r) => r.name.toLowerCase() == request.name.toLowerCase(),
    )) {
      throw RepertoireExistsException(request.name);
    }
    // This preflight supplies a friendly error; createOnly at the storage
    // boundary remains responsible for refusing a competing file creation.
    return createRepertoire(
      storage: _storage,
      name: request.name,
      color: request.color,
      pgnContent: request.pgnContent,
      gameCount: request.gameCount,
      chapterName: request.chapterName,
      splitChapters: request.splitChapters,
    );
  }

  @override
  Future<void> rename(RepertoireMetadata repertoire, String name) async {
    requireSafeFileName(name);
    if (repertoire.name == name) return;
    await _storage.renameRepertoireDirectory(repertoire.filePath, name);
  }

  @override
  Future<void> moveToRecovery(RepertoireMetadata repertoire) =>
      _storage.deleteRepertoireDirectory(repertoire.filePath);
}
