import 'dart:io';
import '../../features/documents/models/pgn_document.dart';
import '../../features/repertoires/models/repertoire_recovery_entry.dart';
import '../../services/storage/io_storage_service.dart';
import '../../features/documents/repositories/pgn_document_store.dart';
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
  LegacyRepertoireCatalogRepository(this._storage, {this.documents});

  final PgnDocumentStore? documents;

  final StorageService _storage;

  @override
  bool get supportsRecovery => Platform.isLinux && _storage is IOStorageService;

  @override
  Future<List<RepertoireMetadata>> listRepertoires() =>
      _storage.listRepertoires();

  @override
  Future<List<RepertoireMetadata>> listChapters(String folderPath) =>
      _storage.listChapters(folderPath);

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
    final documents = this.documents;
    return createRepertoire(
      storage: _storage,
      name: request.name,
      color: request.color,
      pgnContent: request.pgnContent,
      gameCount: request.gameCount,
      chapterName: request.chapterName,
      splitChapters: request.splitChapters,
      createDocument: documents == null
          ? null
          : (path, content) async {
              final result = await documents.create(path, content);
              switch (result) {
                case PgnSaved():
                  return;
                case PgnNameCollision():
                  throw RepertoireExistsException(request.name);
                case PgnWriteFailed(:final error):
                  throw error;
                case PgnWriteUncertain():
                  throw const RepertoireCreationUncertain();
                case PgnConflict():
                  throw StateError(
                    'Document destination changed; reload the library.',
                  );
              }
            },
    );
  }

  @override
  Future<void> rename(RepertoireMetadata repertoire, String name) async {
    requireSafeFileName(name);
    if (repertoire.name == name) return;
    await _storage.renameRepertoireDirectory(repertoire.filePath, name);
  }

  @override
  Future<List<RepertoireRecoveryEntry>> listRecovery() async =>
      _storage is IOStorageService ? _storage.listRepertoireRecovery() : [];

  @override
  Future<void> restore(String id, {String? name}) async {
    final storage = _storage;
    if (storage is! IOStorageService) {
      throw UnsupportedError('Restore is unavailable');
    }
    await storage.restoreRepertoire(id, name: name);
  }

  @override
  Future<void> moveToRecovery(RepertoireMetadata repertoire) =>
      _storage.deleteRepertoireDirectory(repertoire.filePath);
}
