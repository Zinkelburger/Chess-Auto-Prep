import 'dart:io';
import 'package:path/path.dart' as p;
import '../../services/storage/file_mutation_service.dart';
import '../../features/documents/models/pgn_document.dart';
import '../../features/training/models/chapter_layout.dart' show ChapterSummary;
import '../../chess_core/pgn/pgn_text.dart' show extractRepertoireColor;
import '../../chess_core/pgn/repertoire_pgn_text.dart' show chapterHeader;
import '../../services/repertoire_service.dart';
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
  LegacyRepertoireCatalogRepository(this._storage, {required this.documents});

  final PgnDocumentStore documents;

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
  Future<List<ChapterSummary>> chapterSections(String path) =>
      RepertoireService(storage: _storage).courseChaptersInFile(path);

  Future<({Directory root, String path})> _chapterDeletionLocation(
    String path,
  ) {
    final storage = _storage;
    if (!documents.supportsQuarantine || storage is! IOStorageService) {
      throw UnsupportedError(
        'Verified chapter deletion is unavailable on this host.',
      );
    }
    if (!p.isAbsolute(path)) {
      throw ArgumentError('Chapter paths must be absolute.');
    }
    return storage.managedFileLocation(path);
  }

  @override
  Future<PgnOpenResult> prepareChapterDeletion(String path) async {
    try {
      final location = await _chapterDeletionLocation(path);
      final result = await documents.open(path);
      if (result case PgnOpened(:final snapshot)) {
        if (snapshot.path != location.path) {
          throw const UnsafeFileMutation(
            'Chapter deletion refuses symbolic-link aliases.',
          );
        }
      }
      return result;
    } catch (error) {
      return PgnReadFailed(error);
    }
  }

  @override
  Future<PgnQuarantineResult> deleteChapter(PgnSnapshot baseline) async {
    try {
      final location = await _chapterDeletionLocation(baseline.path);
      return await documents.quarantine(
        baseline,
        allowedRoot: location.root.path,
      );
    } catch (error) {
      return PgnQuarantineFailed(error);
    }
  }

  @override
  Future<PgnWriteResult> createChapter({
    required String folderPath,
    required String name,
    bool? isWhite,
  }) async {
    try {
      name = requireSafeFileName(name);
      final path = _storage.chapterFilePath(folderPath, name);
      final chapters = await listChapters(folderPath);
      if (chapters.any(
        (chapter) => chapter.name.toLowerCase() == name.toLowerCase(),
      )) {
        return const PgnNameCollision();
      }
      if (isWhite == null) {
        for (final chapter in chapters) {
          final content = await _storage.readFile(chapter.filePath);
          if (content == null) continue;
          final color = extractRepertoireColor(content);
          if (color == null || color.isEmpty) continue;
          isWhite = color.toLowerCase() != 'black';
          break;
        }
      }
      return await documents.create(
        path,
        chapterHeader(
          name: name,
          isWhite: isWhite ?? true,
          createdAt: DateTime.now(),
        ),
      );
    } catch (error) {
      return PgnWriteFailed(error);
    }
  }

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
      documents: documents,
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
