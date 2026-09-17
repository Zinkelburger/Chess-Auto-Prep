import 'package:path/path.dart' as p;
import '../../features/documents/models/pgn_document.dart';
import '../../features/documents/repositories/pgn_collection_repository.dart';
import '../../features/documents/repositories/pgn_document_store.dart';
import '../../services/storage/storage_service.dart';
import '../../services/pgn_document_patch.dart';
import 'legacy_pgn_document_store.dart';

/// Bridges managed paths while the viewer's library/session reads migrate.
/// Verified hosts use native typed writes; other hosts keep the serialized
/// storage transaction and report an ambiguous write acknowledgement as uncertain.
class StoragePgnCollectionRepository implements PgnCollectionRepository {
  StoragePgnCollectionRepository(this.storage, {this.documents});
  final StorageService storage;
  final PgnDocumentStore? documents;
  PgnDocumentStore get _store => documents ?? LegacyPgnDocumentStore(storage);
  void _checkPath(String path) {
    if (documents != null && !p.isAbsolute(path)) {
      throw ArgumentError('Native collection paths must be absolute');
    }
  }

  @override
  Future<PgnOpenResult> open(String path) async {
    try {
      _checkPath(path);
      return await _store.open(path);
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
      return await _store.create(path, content);
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
      return await _store.save(baseline, content);
    } catch (error) {
      return PgnWriteUncertain(error: error, before: baseline, observed: null);
    }
  }

  @override
  Future<PgnWriteResult> patch(
    String path,
    Map<String, String> replacements,
  ) async {
    final store = documents;
    if (store != null) {
      if (!p.isAbsolute(path)) {
        return PgnWriteFailed(
          ArgumentError('Native collection paths must be absolute'),
        );
      }
      final opened = await store.open(path);
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
      return store.save(opened.snapshot, content);
    }
    String? submitted;
    try {
      await storage.updateFile(path, (current) async {
        if (current == null) throw StateError('The source file is missing.');
        submitted = await patchPgnDocumentAsync(current, replacements);
        return submitted!;
      });
      // Preserve the submitted receipt, never stamp an unseen later write.
      return PgnSaved(
        before: null,
        after: LegacyPgnDocumentStore.snapshot(path, submitted!),
      );
    } on StateError catch (error) {
      if (submitted == null) return const PgnConflict(null);
      return PgnWriteUncertain(error: error, before: null, observed: null);
    } catch (error) {
      return PgnWriteUncertain(error: error, before: null, observed: null);
    }
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
