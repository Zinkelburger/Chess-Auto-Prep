import 'package:path/path.dart' as p;
import '../../features/documents/models/pgn_document.dart';
import '../../features/documents/repositories/pgn_collection_repository.dart';
import '../../features/documents/repositories/pgn_document_store.dart';
import '../../services/storage/storage_service.dart';
import '../../services/pgn_document_patch.dart';

/// Adds collection patching and recovery to the app-selected document store.
/// Publication always validates the snapshot observed before patch computation.
class StoragePgnCollectionRepository implements PgnCollectionRepository {
  StoragePgnCollectionRepository(this.storage, {required this.documents});
  final StorageService storage;
  final PgnDocumentStore documents;
  @override
  bool get supportsQuarantine => documents.supportsQuarantine;
  @override
  Future<PgnQuarantineResult> quarantine(
    PgnSnapshot baseline, {
    String? allowedRoot,
  }) async {
    try {
      _checkPath(baseline.path);
    } catch (error) {
      return PgnQuarantineFailed(error);
    }
    return documents.quarantine(baseline, allowedRoot: allowedRoot);
  }

  void _checkPath(String path) {
    if (!p.isAbsolute(path)) {
      throw ArgumentError('Collection paths must be absolute');
    }
  }

  @override
  Future<PgnOpenResult> open(String path) async {
    try {
      _checkPath(path);
      return await documents.open(path);
    } catch (error) {
      return PgnReadFailed(error);
    }
  }

  @override
  Future<PgnWriteResult> create(String path, String content) async {
    try {
      _checkPath(path);
    } catch (error) {
      return PgnWriteFailed(error);
    }
    try {
      return await documents.create(path, content);
    } catch (error) {
      return PgnWriteUncertain(error: error, before: null, observed: null);
    }
  }

  @override
  Future<PgnWriteResult> save(PgnSnapshot baseline, String content) async {
    try {
      _checkPath(baseline.path);
    } catch (error) {
      return PgnWriteFailed(error);
    }
    try {
      return await documents.save(baseline, content);
    } catch (error) {
      return PgnWriteUncertain(error: error, before: baseline, observed: null);
    }
  }

  @override
  Future<PgnWriteResult> patch(
    String path,
    Map<String, String> replacements,
  ) async {
    final opened = await open(path);
    if (opened is PgnMissing) return const PgnConflict(null);
    if (opened is! PgnOpened) {
      return PgnWriteFailed((opened as PgnReadFailed).error);
    }
    String content;
    try {
      content = await patchPgnDocumentAsync(
        opened.snapshot.content,
        replacements,
      );
    } on StateError {
      return PgnConflict(opened.snapshot);
    }
    // A writer changing even an unrelated game after this observation is a
    // conflict. No retry adopts that newer revision without user action.
    return save(opened.snapshot, content);
  }

  @override
  Future<String?> retainRecovery(String content) async {
    final path = 'recovery/pgn-${DateTime.now().microsecondsSinceEpoch}.pgn';
    await storage.writeFile(path, content, createOnly: true);
    return path;
  }

  @override
  Future<DateTime?> modified(String path) async =>
      (await storage.fileStat(path))?.modified;
}
