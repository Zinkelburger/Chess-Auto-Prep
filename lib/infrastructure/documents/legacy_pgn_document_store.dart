import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../features/documents/models/pgn_document.dart';
import '../../features/documents/repositories/pgn_document_store.dart';
import '../../services/storage/storage_service.dart';
import '../../utils/atomic_file.dart';

/// Content-only compatibility adapter for hosts without the verified native
/// protocol. It cannot detect same-byte replacement; retire with platform gates.
class LegacyPgnDocumentStore implements PgnDocumentStore {
  LegacyPgnDocumentStore(this.storage);
  final StorageService storage;
  @override
  bool get supportsQuarantine => false;
  @override
  Future<PgnQuarantineResult> quarantine(
    PgnSnapshot baseline, {
    String? allowedRoot,
  }) async => PgnQuarantineFailed(
    UnsupportedError('Verified quarantine is unavailable'),
  );

  static PgnSnapshot snapshot(String path, String content) => PgnSnapshot(
    path: path,
    content: content,
    revision: PgnRevision(
      documentId: p.normalize(path),
      nativeIdentity: 'legacy-content',
      sha256: sha256.convert(utf8.encode(content)).toString(),
    ),
  );
  @override
  Future<PgnOpenResult> open(String path) async {
    try {
      final content = await storage.readFile(path);
      return content == null
          ? const PgnMissing()
          : PgnOpened(snapshot(path, content));
    } catch (error) {
      return PgnReadFailed(error);
    }
  }

  @override
  Future<PgnWriteResult> create(String path, String content) =>
      _write(path, content, null);
  @override
  Future<PgnWriteResult> save(PgnSnapshot baseline, String content) =>
      _write(baseline.path, content, baseline);
  Future<PgnWriteResult> _write(
    String path,
    String content,
    PgnSnapshot? before,
  ) async {
    try {
      await storage.writeFile(
        path,
        content,
        createOnly: before == null,
        expectedContent: before?.content,
      );
      // This receipt describes the bytes submitted, never a later external edit.
      return PgnSaved(before: before, after: snapshot(path, content));
    } on AtomicWriteConflict {
      if (before == null) return const PgnNameCollision();
      final current = await open(path);
      return PgnConflict(current is PgnOpened ? current.snapshot : null);
    } catch (error) {
      final observed = await open(path);
      // A legacy exception cannot distinguish a failed commit acknowledgement.
      return PgnWriteUncertain(
        error: error,
        before: before,
        observed: observed is PgnOpened ? observed.snapshot : null,
      );
    }
  }
}
