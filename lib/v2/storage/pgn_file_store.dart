import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'backups.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'document_relocation.dart';
import 'mutation_guards.dart';
import 'pending_repoint.dart';
import 'pgn_document_store.dart';
import 'training_records.dart' as training;

/// The documents root as files on disk.
///
/// Every mutation runs under the directory lock the old app also takes, so the
/// two apps cannot write one folder at once, and publishes through the atomic
/// writer, so a reader never sees half a document. Reads take no lock: the
/// native probe takes bytes and identity from one open handle, and a
/// publication is one rename, so a reader gets the whole old file or the whole
/// new one either way.
///
/// What that does and does not promise. Against the old app and against
/// another copy of this one, which take the same lock, a mutation is
/// exclusive and neither side can lose the other's write. Against a program
/// that does not take the lock — a text editor, a sync client — the file is
/// read again immediately before it is replaced and the mutation refuses on
/// any change, but that check and the rename are two system calls, so a write
/// that lands between them is replaced rather than reported. What was
/// replaced is kept in Support before the rename, so even then nothing is
/// gone for good.
///
/// Renaming, moving and deleting change where a document lives rather than
/// what is in it; they are in [DocumentRelocation].
final class PgnFileStore implements PgnDocumentStore {
  factory PgnFileStore({
    required Directory documents,
    required Directory support,
  }) {
    final backups = BackupArchive(Directory(p.join(support.path, 'backups')));
    return PgnFileStore._(
      documents,
      backups,
      DocumentRelocation(
        documents: documents,
        backups: backups,
        records: training.TrainingRecords(documents),
        unfinished: PendingRepoints(support),
      ),
    );
  }

  PgnFileStore._(this.documents, this._backups, this._relocation);

  /// The folder every document lives under; a ref outside it is refused.
  final Directory documents;

  final BackupArchive _backups;
  final DocumentRelocation _relocation;

  @override
  Future<DocumentRead> open(DocumentRef ref) async {
    switch (await probeDocument(ref.path)) {
      case FileMissing():
        return const Absent();
      case FileUnreadable(:final detail):
        log.w('open ${ref.path}', detail);
        return Unreadable(detail);
      case FileFound(:final bytes, :final revision):
        return Opened(_decode(bytes), revision);
    }
  }

  @override
  Future<CreateResult> create(DocumentRef ref, String text) async {
    // Before anything reaches the disk: a ref outside the root must not make
    // folders outside the root either.
    if (documentBackupIdFor(documents, ref) == null) {
      return const IoFailure(outsideRoot);
    }
    try {
      await folderOf(ref).create(recursive: true);
    } on FileSystemException catch (error) {
      log.e('create ${ref.path}', error);
      return IoFailure(failureDetail(error));
    }
    return lockedForDocument(
      folderOf(ref),
      ref,
      () => _create(ref, text),
      IoFailure.new,
    );
  }

  Future<CreateResult> _create(DocumentRef ref, String text) async {
    try {
      await removeStaleTemporaries(folderOf(ref));
      await createFileExclusively(ref.path, utf8.encode(text));
    } on NativeNameCollision {
      return const Collision();
    } on Object catch (error) {
      log.e('create ${ref.path}', error);
      return IoFailure(failureDetail(error));
    }
    final revision = await _revisionOf(ref.path, 'create ${ref.path}');
    return revision == null ? const IoFailure(_unread) : Created(revision);
  }

  @override
  Future<SaveResult> save(
    DocumentRef ref,
    String text, {
    required Revision expected,
  }) => lockedForDocument(
    folderOf(ref),
    ref,
    () => _save(ref, text, expected),
    IoFailure.new,
  );

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
    final bytes = utf8.encode(text);
    // Nothing to replace, so nothing to keep and nothing to write.
    if (sha256.convert(bytes).toString() == revision.contentHash) {
      return Saved(_receipt(before, revision, revision));
    }
    final refused = await keepReplacedVersion(
      backups: _backups,
      documents: documents,
      ref: ref,
      bytes: current,
      hash: revision.contentHash,
    );
    if (refused != null) return refused;
    // Keeping the replaced version awaited the disk, and an editor outside
    // the lock could have written the file meanwhile.
    final changed = await _recheck(ref, revision);
    if (changed != null) return changed;
    try {
      await removeStaleTemporaries(folderOf(ref));
      await replaceFile(ref.path, bytes);
    } on Object catch (error) {
      log.e('save ${ref.path}', error);
      return IoFailure(failureDetail(error));
    }
    final committed = await _revisionOf(ref.path, 'save ${ref.path}');
    if (committed == null) return const IoFailure(_unread);
    return Saved(_receipt(before, revision, committed));
  }

  /// What to answer with when [ref] no longer holds [expected]; null while it
  /// still does.
  Future<SaveResult?> _recheck(DocumentRef ref, Revision expected) async {
    switch (await probeDocument(ref.path)) {
      case FileMissing():
        return const Conflict(null);
      case FileUnreadable(:final detail):
        log.w('save ${ref.path}', detail);
        return IoFailure(detail);
      case FileFound(:final revision):
        return revision == expected ? null : Conflict(revision);
    }
  }

  @override
  Future<MoveResult> rename(
    DocumentRef ref,
    String name, {
    required Revision expected,
  }) => _relocation.rename(ref, name, expected: expected);

  @override
  Future<MoveResult> move(
    DocumentRef ref,
    DocumentRef destination, {
    required Revision expected,
  }) => _relocation.move(ref, destination, expected: expected);

  @override
  Future<FolderMoveResult> moveFolder(String from, String to) =>
      _relocation.moveFolder(from, to);

  @override
  Future<DeleteResult> delete(DocumentRef ref, {required Revision expected}) =>
      _relocation.delete(ref, expected: expected);

  Future<Revision?> _revisionOf(String path, String action) async {
    final probe = await probeDocument(path);
    if (probe case FileFound(:final revision)) return revision;
    log.e(action, _unread);
    return null;
  }

  Receipt _receipt(String before, Revision was, Revision committed) =>
      Receipt(committed: committed, before: before, beforeRevision: was);
}

const _unread = 'the file could not be read back after writing';

/// Valid non-ASCII characters per stray byte for a file to keep its UTF-8
/// reading. The old app's number, and both apps must read one file the same
/// way.
const _validToStrayRatio = 8;

/// The text in [bytes], read as the old app reads the same files, so every
/// PGN it opens opens here too. Whatever came in, a save writes UTF-8 back.
///
/// Strict UTF-8 first. A file that fails it is one of two things. A Latin-1
/// file fails on its first accented letter and holds no valid multi-byte
/// sequence anywhere, so it is decoded as Latin-1. A UTF-8 file with a few
/// damaged bytes among thousands of good ones — a course export with four
/// control bytes in ten megabytes of curly quotes — keeps its UTF-8 reading
/// with the stray bytes as U+FFFD, because reading it as Latin-1 would turn
/// every one of those quotes into mojibake.
String _decode(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    final tolerant = utf8.decode(bytes, allowMalformed: true);
    var strays = 0;
    var valid = 0;
    for (final unit in tolerant.codeUnits) {
      if (unit == 0xFFFD) {
        strays++;
      } else if (unit > 0x7F) {
        valid++;
      }
    }
    return valid >= strays * _validToStrayRatio
        ? tolerant
        : latin1.decode(bytes);
  }
}
