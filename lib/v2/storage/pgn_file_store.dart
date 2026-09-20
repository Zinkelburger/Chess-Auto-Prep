import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'backups.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'file_lock.dart';
import 'pgn_document_store.dart';

/// The documents root as files on disk.
///
/// Every mutation runs under the directory lock the old app also takes, so the
/// two apps cannot write one folder at once, and publishes through the atomic
/// writer, so a reader never sees half a document. Reads take no lock: the
/// native probe takes bytes and identity from one open handle, and a
/// publication is one rename, so a reader gets the whole old file or the whole
/// new one either way.
final class PgnFileStore implements PgnDocumentStore {
  PgnFileStore({required this.documents, required Directory support})
    : _backups = BackupArchive(Directory(p.join(support.path, 'backups')));

  /// The folder every document lives under; a ref outside it is refused.
  final Directory documents;

  final BackupArchive _backups;

  @override
  Future<DocumentRead> open(DocumentRef ref) async {
    switch (await probeDocument(ref.path)) {
      case FileMissing():
        return const Absent();
      case FileUnreadable(:final detail):
        log.w('open ${ref.path}', detail);
        return Unreadable(detail);
      case FileFound(:final bytes, :final revision):
        final text = _decode(bytes);
        if (text == null) {
          log.w('open ${ref.path}', _notText);
          return const Unreadable(_notText);
        }
        return Opened(text, revision);
    }
  }

  @override
  Future<CreateResult> create(DocumentRef ref, String text) async {
    // Before anything reaches the disk: a ref outside the root must not make
    // folders outside the root either.
    if (_idFor(ref) == null) return const IoFailure(_outsideRoot);
    try {
      await _folder(ref).create(recursive: true);
    } on FileSystemException catch (error) {
      log.e('create ${ref.path}', error);
      return IoFailure(_detail(error));
    }
    return _locked(ref, () => _create(ref, text), IoFailure.new);
  }

  Future<CreateResult> _create(DocumentRef ref, String text) async {
    try {
      await removeStaleTemporaries(_folder(ref));
      await createFileExclusively(ref.path, utf8.encode(text));
    } on NativeNameCollision {
      return const Collision();
    } on Object catch (error) {
      log.e('create ${ref.path}', error);
      return IoFailure(_detail(error));
    }
    final revision = await _revisionOf(ref.path, 'create ${ref.path}');
    return revision == null ? const IoFailure(_unread) : Created(revision);
  }

  @override
  Future<SaveResult> save(
    DocumentRef ref,
    String text, {
    required Revision expected,
  }) => _locked(ref, () => _save(ref, text, expected), IoFailure.new);

  Future<SaveResult> _save(
    DocumentRef ref,
    String text,
    Revision expected,
  ) async {
    switch (await probeDocument(ref.path)) {
      case FileMissing():
        return const Conflict(null);
      case FileUnreadable(:final detail):
        log.w('save ${ref.path}', detail);
        return IoFailure(detail);
      case FileFound(:final bytes, :final revision):
        if (revision != expected) return Conflict(revision);
        return _replace(ref, text, bytes, revision);
    }
  }

  Future<SaveResult> _replace(
    DocumentRef ref,
    String text,
    List<int> current,
    Revision revision,
  ) async {
    final before = _decode(current);
    if (before == null) return const IoFailure(_notText);
    final bytes = utf8.encode(text);
    // Nothing to replace, so nothing to keep and nothing to write.
    if (sha256.convert(bytes).toString() == revision.contentHash) {
      return Saved(_receipt(before, revision, revision));
    }
    final refused = await _keep(ref, current, revision.contentHash);
    if (refused != null) return refused;
    try {
      await removeStaleTemporaries(_folder(ref));
      await replaceFile(ref.path, bytes);
    } on Object catch (error) {
      log.e('save ${ref.path}', error);
      return IoFailure(_detail(error));
    }
    final committed = await _revisionOf(ref.path, 'save ${ref.path}');
    if (committed == null) return const IoFailure(_unread);
    return Saved(_receipt(before, revision, committed));
  }

  @override
  Future<MoveResult> rename(
    DocumentRef ref,
    String name, {
    required Revision expected,
  }) => move(
    ref,
    DocumentRef(p.join(p.dirname(ref.path), name)),
    expected: expected,
  );

  @override
  Future<MoveResult> move(
    DocumentRef ref,
    DocumentRef destination, {
    required Revision expected,
  }) => _locked(ref, () => _move(ref, destination, expected), IoFailure.new);

  Future<MoveResult> _move(
    DocumentRef ref,
    DocumentRef destination,
    Revision expected,
  ) async {
    final from = _idFor(ref);
    final to = _idFor(destination);
    if (from == null || to == null) return const IoFailure(_outsideRoot);
    switch (await probeDocument(ref.path)) {
      case FileMissing():
        return const Conflict(null);
      case FileUnreadable(:final detail):
        log.w('move ${ref.path}', detail);
        return IoFailure(detail);
      case FileFound(:final revision):
        if (revision != expected) return Conflict(revision);
        return _relocate(ref, destination, from, to, revision);
    }
  }

  Future<MoveResult> _relocate(
    DocumentRef ref,
    DocumentRef destination,
    String from,
    String to,
    Revision revision,
  ) async {
    final target = Directory(p.dirname(destination.path));
    try {
      await target.create(recursive: true);
      await movePathNoReplace(ref.path, destination.path);
    } on NativeNameCollision {
      return const Collision();
    } on Object catch (error) {
      log.e('move ${ref.path}', error);
      return IoFailure(_detail(error));
    }
    await _backups.adopt(from: from, to: to, documentPath: destination.path);
    await _sync(_folder(ref));
    await _sync(target);
    // Same bytes in the same file: the caller's revision still describes it.
    return Moved(revision);
  }

  @override
  Future<DeleteResult> delete(DocumentRef ref, {required Revision expected}) =>
      _locked(ref, () => _delete(ref, expected), IoFailure.new);

  Future<DeleteResult> _delete(DocumentRef ref, Revision expected) async {
    switch (await probeDocument(ref.path)) {
      case FileMissing():
        return const Conflict(null);
      case FileUnreadable(:final detail):
        log.w('delete ${ref.path}', detail);
        return IoFailure(detail);
      case FileFound(:final bytes, :final revision):
        if (revision != expected) return Conflict(revision);
        return _quarantine(ref, bytes, revision);
    }
  }

  /// Deleting is moving: into the same folder the old app quarantines
  /// chapters into, so the user has one place to look for what they removed.
  Future<DeleteResult> _quarantine(
    DocumentRef ref,
    List<int> bytes,
    Revision revision,
  ) async {
    final refused = await _keep(ref, bytes, revision.contentHash);
    if (refused != null) return refused;
    final trash = Directory(p.join(p.dirname(ref.path), _recoveryFolder));
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final token = Random.secure().nextInt(1 << 32).toRadixString(16);
    final target = p.join(trash.path, '$stamp-$token-${p.basename(ref.path)}');
    try {
      await trash.create(recursive: true);
      await movePathNoReplace(ref.path, target);
    } on Object catch (error) {
      log.e('delete ${ref.path}', error);
      return IoFailure(_detail(error));
    }
    await _sync(_folder(ref));
    return Deleted(target);
  }

  /// Records the version about to be replaced. A version that could not be
  /// kept stops the write: [IoFailure] here means the document is untouched.
  Future<IoFailure?> _keep(
    DocumentRef ref,
    List<int> bytes,
    String hash,
  ) async {
    final id = _idFor(ref);
    if (id == null) return const IoFailure(_outsideRoot);
    final outcome = await _backups.record(
      id: id,
      documentPath: ref.path,
      bytes: bytes,
      hash: hash,
    );
    return switch (outcome) {
      BackupRecorded() || BackupSkipped() => null,
      BackupFailed(:final detail) => IoFailure(
        'the version being replaced could not be kept: $detail',
      ),
    };
  }

  Future<T> _locked<T>(
    DocumentRef ref,
    Future<T> Function() action,
    T Function(String detail) failed,
  ) async {
    try {
      return await withDirectoryLock(_folder(ref), action);
    } on FileSystemException catch (error) {
      log.e('take the folder lock for ${ref.path}', error);
      return failed(_detail(error));
    }
  }

  Future<Revision?> _revisionOf(String path, String action) async {
    final probe = await probeDocument(path);
    if (probe case FileFound(:final revision)) return revision;
    log.e(action, _unread);
    return null;
  }

  Future<void> _sync(Directory directory) async {
    try {
      await syncDirectory(directory.path);
    } on FileSystemException catch (error) {
      log.w('flush ${directory.path}', error);
    }
  }

  Receipt _receipt(String before, Revision was, Revision committed) =>
      Receipt(committed: committed, before: before, beforeRevision: was);

  Directory _folder(DocumentRef ref) => Directory(p.dirname(ref.path));

  /// The id this document's kept versions live under, or null when the ref
  /// names something outside the documents root.
  String? _idFor(DocumentRef ref) => p.isWithin(documents.path, ref.path)
      ? backupId(p.relative(ref.path, from: documents.path))
      : null;
}

/// The old app's chapter quarantine folder; both apps delete into it.
const _recoveryFolder = '.cap-pgn-history';
const _notText = 'the file is not UTF-8 text';
const _outsideRoot = 'that path is outside the documents folder';
const _unread = 'the file could not be read back after writing';

String? _decode(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

String _detail(Object error) => error is FileSystemException
    ? error.osError?.message ?? error.message
    : '$error';
