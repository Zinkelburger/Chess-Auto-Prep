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
/// A save also has to survive the app itself. It says which games it means
/// to change ([EditScope]); before anything is written, the text is compared
/// with the version on disk game by game and a change to any other game
/// stops the write; after the rename, the file is read again and refused as
/// unverified if it does not hold the bytes that went out. Either way the
/// version being replaced is already in Support, so nothing is gone.
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
        switch (readDocumentText(bytes)) {
          case PlainText(:final text):
            return Opened(text, revision);
          case NotText(:final detail):
            log.w('open ${ref.path}', detail);
            return Unreadable(detail);
        }
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
    if (revision != null) return Created(revision);
    // The file is there — it was just written — so this is not the document
    // being as it was. Whoever asked has to be told the name is taken by
    // something nobody has read.
    return WriteUnverified('$_unread; it is at ${ref.path}');
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
    List<int> current,
    Revision revision,
    EditScope scope,
  ) async {
    final read = readDocumentText(current);
    // A document this app cannot read is not one it may replace: a save over
    // a compressed chapter would leave bytes neither app can open.
    if (read case NotText(:final detail)) {
      log.w('save ${ref.path}', detail);
      return IoFailure(detail);
    }
    final before = (read as PlainText).text;
    final bytes = utf8.encode(text);
    final written = sha256.convert(bytes).toString();
    // Nothing to replace, so nothing to keep and nothing to write.
    if (written == revision.contentHash) {
      return Saved(_receipt(before, revision, revision));
    }
    final refused = _onlyWhatWasDeclared(ref, current, bytes, scope);
    if (refused != null) return refused;
    final unkept = await keepReplacedVersion(
      backups: _backups,
      documents: documents,
      ref: ref,
      bytes: current,
      hash: revision.contentHash,
    );
    if (unkept != null) return unkept;
    if (!await _keptIsTheVersionBeingReplaced(ref, revision)) {
      log.e('save ${ref.path}', _unkept);
      return const IoFailure(_unkept);
    }
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
    return _committed(ref, before, revision, written);
  }

  /// Why [next] may not be written over [current], or null when it changes
  /// only what [scope] declared. A save that replaces the whole document is
  /// not refused — there is nothing to compare it against — but it is
  /// logged, so a caller that rewrites a chapter without saying what it
  /// edited is visible.
  SaveResult? _onlyWhatWasDeclared(
    DocumentRef ref,
    List<int> current,
    List<int> next,
    EditScope scope,
  ) {
    final outside = changeOutsideScope(
      previous: current,
      next: next,
      scope: scope,
    );
    if (outside != null) {
      log.e('save ${ref.path}', outside);
      return SaveRefused(outside);
    }
    if (scope is WholeDocument) log.w('save ${ref.path}', _undeclared);
    return null;
  }

  /// Whether the version just recorded is on the disk, readable, and the one
  /// this save is replacing.
  ///
  /// The text compared above came out of the bytes the revision describes,
  /// so a kept copy hashing to that revision holds those same bytes: the
  /// comparison stands for the copy in Support as much as for the file, and
  /// the write only goes ahead once the previous version is safe somewhere
  /// else.
  Future<bool> _keptIsTheVersionBeingReplaced(
    DocumentRef ref,
    Revision revision,
  ) async {
    final id = documentBackupIdFor(documents, ref);
    final kept = id == null ? null : await _backups.newestVersion(id);
    return kept != null &&
        sha256.convert(kept).toString() == revision.contentHash;
  }

  /// The receipt of a write that landed, or the failure that says the file
  /// does not hold the bytes [written] names.
  ///
  /// The file is read again rather than assumed: a rename that reported
  /// success over a filesystem that lied, or anything that wrote the name
  /// between the rename and now, would otherwise be a silent loss. A file
  /// nothing can read now is the same news: the rename happened, so the
  /// document is not as it was, and saying it failed would leave the app
  /// expecting the old revision and calling this app's own write somebody
  /// else's.
  Future<SaveResult> _committed(
    DocumentRef ref,
    String before,
    Revision was,
    String written,
  ) async {
    final committed = await _revisionOf(ref.path, 'save ${ref.path}');
    if (committed == null) return WriteUnverified(_notHeld(ref, _unread));
    if (committed.contentHash != written) {
      return WriteUnverified(
        _notHeld(ref, 'the file does not hold what was just written to it'),
      );
    }
    return Saved(_receipt(before, was, committed));
  }

  String _notHeld(DocumentRef ref, String detail) {
    final said =
        '$detail; the version it replaced is kept in '
        '${_keptFolder(ref)}';
    log.e('save ${ref.path}', said);
    return said;
  }

  String _keptFolder(DocumentRef ref) {
    final id = documentBackupIdFor(documents, ref);
    return id == null ? _backups.root.path : _backups.folderFor(id).path;
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

const _unkept =
    'the version being replaced could not be read back from the copy kept '
    'for it';

const _undeclared =
    'the whole document was replaced; the save did not say which game it '
    'changed';
