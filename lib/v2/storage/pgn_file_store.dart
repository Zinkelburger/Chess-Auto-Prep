import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../chess/pgn/chapter.dart' show readOffThreadFrom;
import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'backups.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'document_relocation.dart';
import 'document_text.dart';
import 'edit_scope.dart';
import 'mutation_guards.dart';
import 'relocation_notes.dart';
import 'pgn_document_store.dart';
import 'training_records.dart' as training;

/// The documents root as files on disk.
///
/// Every mutation runs under the directory lock the old app also takes, so the
/// two apps cannot write one folder at once, and publishes through the atomic
/// writer, so a reader never sees half a document. Reads take no lock: the
/// native probe takes bytes and hash from one open handle, and a publication
/// is one rename, so a reader gets the whole old file or the whole new one
/// either way.
///
/// What that does and does not promise. Against the old app and against
/// another copy of this one, which take the same lock, a mutation is
/// exclusive and neither side can lose the other's write. Against a program
/// that does not take the lock — a text editor, a sync client — the file is
/// read under the lock and the mutation refuses on any change since the
/// caller's read, but that check and the rename are separate system calls.
/// What is kept in Support before the rename is the version this app read at
/// that check, so every version this app replaces can be had back; a write by
/// a program that took no lock and landed in the moment between the check and
/// the rename is replaced without being reported, and those bytes are in no
/// kept version.
///
/// A save also has to survive the app itself. It says which games it means
/// to change ([EditScope]); before anything is written, the text is compared
/// with the version on disk game by game and a change to any other game
/// stops the write. That comparison, and everything else that touches every
/// byte of the file, runs on another isolate.
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
        notes: RelocationNotes(
          notes: PendingRepoints(support),
          records: training.TrainingRecords(documents),
        ),
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
        switch (await _decoded(bytes)) {
          case PlainText(:final text):
            return Opened(text, revision, readOnly: _outsideRoot(ref));
          case ForeignText(:final text, :final detail):
            log.w('open ${ref.path}', detail);
            return Opened(
              text,
              revision,
              readOnly: _outsideRoot(ref) ?? detail,
            );
          case NotText(:final detail):
            log.w('open ${ref.path}', detail);
            return Unreadable(detail);
        }
    }
  }

  /// Why a file at [ref] opens to read, or null when it may be written.
  ///
  /// Every write keeps the version it replaces under an id made from the
  /// path inside the documents folder, so a file outside it has nowhere for
  /// its versions to go and no write ever reaches it. It is still read: the
  /// viewer opens whatever the user browses to.
  String? _outsideRoot(DocumentRef ref) =>
      documentBackupIdFor(documents, ref) == null
      ? 'it is outside your Documents folder'
      : null;

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
    final bytes = await _encoded(text);
    try {
      await removeStaleTemporaries(folderOf(ref));
      await createFileExclusively(ref.path, bytes.bytes);
    } on NativeNameCollision {
      return const Collision();
    } on Object catch (error) {
      log.e('create ${ref.path}', error);
      return IoFailure(failureDetail(error));
    }
    return Created(Revision(bytes.hash));
  }

  @override
  Future<SaveResult> save(
    DocumentRef ref,
    String text, {
    required Revision expected,
    required EditScope scope,
  }) => lockedForDocument(
    folderOf(ref),
    ref,
    () => _save(ref, text, expected, scope),
    IoFailure.new,
  );

  Future<SaveResult> _save(
    DocumentRef ref,
    String text,
    Revision expected,
    EditScope scope,
  ) async {
    switch (await probeDocument(ref.path)) {
      case FileMissing():
        return const Conflict(null);
      case FileUnreadable(:final detail):
        log.w('save ${ref.path}', detail);
        return IoFailure(detail);
      case FileFound(:final bytes, :final revision):
        if (revision != expected) return Conflict(revision);
        return _replace(ref, text, bytes, revision, scope);
    }
  }

  Future<SaveResult> _replace(
    DocumentRef ref,
    String text,
    Uint8List current,
    Revision revision,
    EditScope scope,
  ) async {
    final prepared = await _prepared(
      current,
      revision.contentHash,
      text,
      scope,
    );
    switch (prepared) {
      case _NotReplaceable(:final result, :final detail):
        log.w('save ${ref.path}', detail);
        return result;
      case _OutsideScope(:final detail):
        log.e('save ${ref.path}', detail);
        return SaveRefused(detail);
      case _Unchanged(:final before):
        // Nothing to replace, so nothing to keep and nothing to write.
        return Saved(_receipt(before, revision, revision));
      case _Ready(:final before, :final bytes, :final hash, :final undeclared):
        if (undeclared) log.w('save ${ref.path}', _undeclared);
        if (scope is RestoredVersion) {
          final refused = await _keptHere(ref, hash);
          if (refused != null) return refused;
        }
        final unkept = await keepReplacedVersion(
          backups: _backups,
          documents: documents,
          ref: ref,
          bytes: current,
          hash: revision.contentHash,
        );
        if (unkept != null) return unkept;
        try {
          await removeStaleTemporaries(folderOf(ref));
          await replaceFile(ref.path, bytes);
        } on Object catch (error) {
          log.e('save ${ref.path}', error);
          return IoFailure(failureDetail(error));
        }
        return Saved(_receipt(before, revision, Revision(hash)));
    }
  }

  /// Why [hash] is not a version this store kept for [ref], or null when it
  /// is one.
  ///
  /// A restore is the one write with nothing to compare against, so it is
  /// compared against the archive instead: bytes that hash to no version
  /// kept for this document are not a version being put back, whatever the
  /// caller called them.
  Future<SaveResult?> _keptHere(DocumentRef ref, String hash) async {
    final id = documentBackupIdFor(documents, ref);
    final kept = id == null ? null : await _backups.versionWithHash(id, hash);
    if (kept == null) {
      log.e('restore ${ref.path}', _unkeptVersion);
      return const RestoreRefused(_unkeptVersion);
    }
    log.i('restore ${ref.path} to the version of ${kept.time}');
    return null;
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

  Receipt _receipt(String before, Revision was, Revision committed) =>
      Receipt(committed: committed, before: before, beforeRevision: was);
}

/// [bytes] as a document. A small file is decoded here; a large one on
/// another isolate, because decoding megabytes is work the screen would
/// otherwise wait for.
Future<DocumentText> _decoded(Uint8List bytes) =>
    bytes.length < readOffThreadFrom
    ? Future.value(readDocumentText(bytes))
    : Isolate.run(() => readDocumentText(bytes));

/// [text] as the bytes a file will hold, and their hash.
Future<({Uint8List bytes, String hash})> _encoded(String text) =>
    text.length < readOffThreadFrom
    ? Future.value(_encode(text))
    : Isolate.run(() => _encode(text));

/// What a save works out before it writes, on another isolate once either
/// side of the comparison is big enough to be worth the trip.
Future<_Prepared> _prepared(
  Uint8List current,
  String currentHash,
  String text,
  EditScope scope,
) => current.length < readOffThreadFrom && text.length < readOffThreadFrom
    ? Future.value(_prepare(current, currentHash, text, scope))
    : Isolate.run(() => _prepare(current, currentHash, text, scope));

({Uint8List bytes, String hash}) _encode(String text) {
  final bytes = utf8.encode(text);
  return (bytes: bytes, hash: sha256.convert(bytes).toString());
}

/// Everything a save works out before it touches the disk: whether the
/// current bytes may be replaced at all, whether the new text changes only
/// what the scope declared, and the bytes and hash to write.
sealed class _Prepared {
  const _Prepared();
}

/// The file on disk is not one this app may replace; [result] says so.
final class _NotReplaceable extends _Prepared {
  const _NotReplaceable(this.result, this.detail);

  final SaveResult result;
  final String detail;
}

/// The text would change a game the save did not declare.
final class _OutsideScope extends _Prepared {
  const _OutsideScope(this.detail);

  final String detail;
}

/// The text is already what the file holds.
final class _Unchanged extends _Prepared {
  const _Unchanged(this.before);

  final String before;
}

final class _Ready extends _Prepared {
  const _Ready({
    required this.before,
    required this.bytes,
    required this.hash,
    required this.undeclared,
  });

  /// The text being replaced, as it was read from disk.
  final String before;

  final Uint8List bytes;
  final String hash;

  /// Whether the save replaced the whole document without saying which
  /// game it changed, which is logged so that a writer that does it is
  /// visible.
  final bool undeclared;
}

/// Runs on another isolate: everything about a save that reads every byte.
_Prepared _prepare(
  Uint8List current,
  String currentHash,
  String text,
  EditScope scope,
) {
  final read = readDocumentText(current);
  // A document this app cannot read is not one it may replace: a save over
  // a compressed chapter would leave bytes neither app can open.
  if (read case NotText(:final detail)) {
    return _NotReplaceable(IoFailure(detail), detail);
  }
  // Nor one it had to guess at: this writes UTF-8, so putting a Latin-1
  // file back would change every game holding an accented letter.
  if (read case ForeignText(:final detail)) {
    return _NotReplaceable(NotWritable(detail), detail);
  }
  final before = (read as PlainText).text;
  final encoded = _encode(text);
  if (encoded.hash == currentHash) return _Unchanged(before);
  final outside = changeOutsideScope(
    previous: current,
    next: encoded.bytes,
    scope: scope,
  );
  if (outside != null) return _OutsideScope(outside);
  return _Ready(
    before: before,
    bytes: encoded.bytes,
    hash: encoded.hash,
    undeclared: scope is WholeDocument,
  );
}

const _unkeptVersion =
    'the save said it was putting a kept version back, and these are not the '
    'bytes of any version kept for this document';

const _undeclared =
    'the whole document was replaced; the save did not say which game it '
    'changed';
