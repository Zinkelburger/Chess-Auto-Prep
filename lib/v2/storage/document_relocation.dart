/// Where a document lives: renaming it, moving it to another folder, and
/// deleting it, which is a move into the recovery folder.
///
/// These mutations change the name rather than the bytes, so they end in a
/// rename on disk rather than a publication. They share with the store's
/// create and save the guards every mutation takes — the directory lock, the
/// id a document's kept versions live under, and recording the version about
/// to be replaced — which is why those guards live here rather than beside
/// one of the two callers.
library;

import 'dart:io';
import 'dart:math';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'backups.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'file_lock.dart';
import 'pgn_document_store.dart';
import 'training_records.dart' as training;

/// The rename, move and delete half of [PgnDocumentStore], over the same
/// documents root, kept versions and training records the store was built
/// with.
final class DocumentRelocation {
  DocumentRelocation({
    required this.documents,
    required BackupArchive backups,
    required training.TrainingRecords records,
  }) : _backups = backups,
       _training = records;

  /// The folder every document lives under; a ref outside it is refused.
  final Directory documents;

  final BackupArchive _backups;
  final training.TrainingRecords _training;

  /// Gives [ref] a new file name in the same folder, which is a move.
  Future<MoveResult> rename(
    DocumentRef ref,
    String name, {
    required Revision expected,
  }) => move(
    ref,
    DocumentRef(p.join(p.dirname(ref.path), name)),
    expected: expected,
  );

  /// Moving holds the lock on the documents root rather than on either
  /// folder, because that is the scope the old app takes for the same
  /// operation (`io_storage_service.dart`, `_rootForMove`). Two apps renaming
  /// one chapter must exclude each other, and no one folder covers both ends
  /// of a move.
  Future<MoveResult> move(
    DocumentRef ref,
    DocumentRef destination, {
    required Revision expected,
  }) async {
    final result = await lockedForDocument(
      documents,
      ref,
      () => _move(ref, destination, expected),
      IoFailure.new,
    );
    // Outside the folder lock, which is not re-entrant: the training files
    // live in the documents root, which can be the folder just locked.
    if (result case Moved(:final revision)) {
      return Moved(
        revision,
        training: await _training.repoint(ref, destination),
      );
    }
    return result;
  }

  Future<MoveResult> _move(
    DocumentRef ref,
    DocumentRef destination,
    Revision expected,
  ) async {
    final from = documentBackupIdFor(documents, ref);
    final to = documentBackupIdFor(documents, destination);
    if (from == null || to == null) return const IoFailure(outsideRoot);
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
    final made = !await target.exists();
    try {
      if (made) await target.create(recursive: true);
      await movePathNoReplace(ref.path, destination.path);
    } on NativeNameCollision {
      await _removeIfMade(target, made);
      return const Collision();
    } on Object catch (error) {
      log.e('move ${ref.path}', error);
      await _removeIfMade(target, made);
      return IoFailure(failureDetail(error));
    }
    await _backups.adopt(from: from, to: to, documentPath: destination.path);
    await _sync(folderOf(ref));
    await _sync(target);
    // Same bytes in the same file: the caller's revision still describes it.
    return Moved(revision);
  }

  /// Moves a whole folder of documents — a repertoire — in one rename.
  ///
  /// The lock is the documents root, as [move] takes it: no one folder covers
  /// both ends of a move, and here neither end is a folder anything else
  /// locks. The kept versions follow each document inside, because a
  /// document's history is kept under a hash of its path rather than under
  /// its folder's; a history that cannot be moved is left where it is and
  /// never fails the move, exactly as it does for one document.
  Future<FolderMoveResult> moveFolder(String from, String to) async {
    final result = await lockedForDocument(
      documents,
      DocumentRef(from),
      () => _moveFolder(from, to),
      FolderMoveFailed.new,
    );
    // Outside the folder lock, which is not re-entrant: the training files
    // live in the documents root, which is the folder just locked. `repoint`
    // rewrites every row inside a folder that moved, not just exact matches.
    if (result is FolderMoved) {
      return FolderMoved(
        training: await _training.repoint(DocumentRef(from), DocumentRef(to)),
      );
    }
    return result;
  }

  Future<FolderMoveResult> _moveFolder(String from, String to) async {
    if (!p.isWithin(documents.path, from) || !p.isWithin(documents.path, to)) {
      return const FolderMoveFailed(outsideRoot);
    }
    // Read before the move, because afterwards the old names are gone.
    final documentNames = await _documentsIn(from);
    if (documentNames == null) return const FolderMoveFailed(_unlistable);
    try {
      await movePathNoReplace(from, to);
    } on NativeNameCollision {
      return const FolderNameTaken();
    } on Object catch (error) {
      log.e('move the folder $from', error);
      return FolderMoveFailed(failureDetail(error));
    }
    await _adoptAll(documentNames, from, to);
    await _sync(Directory(p.dirname(from)));
    await _sync(Directory(p.dirname(to)));
    return const FolderMoved();
  }

  /// Hands each document's kept versions to the name it now has.
  Future<void> _adoptAll(List<String> names, String from, String to) async {
    for (final name in names) {
      final moved = p.join(to, name);
      await _backups.adopt(
        from: backupId(p.relative(p.join(from, name), from: documents.path)),
        to: backupId(p.relative(moved, from: documents.path)),
        documentPath: moved,
      );
    }
  }

  /// The PGN file names directly in [folder], or null when it cannot be
  /// listed — which is a reason not to move it at all.
  Future<List<String>?> _documentsIn(String folder) async {
    final names = <String>[];
    try {
      await for (final entry in Directory(folder).list()) {
        if (entry is File && p.extension(entry.path) == '.pgn') {
          names.add(p.basename(entry.path));
        }
      }
    } on FileSystemException catch (error) {
      log.e('list $folder before moving it', error);
      return null;
    }
    return names;
  }

  /// Moves [ref] into the recovery folder beside it.
  Future<DeleteResult> delete(
    DocumentRef ref, {
    required Revision expected,
  }) async {
    final result = await lockedForDocument(
      folderOf(ref),
      ref,
      () => _delete(ref, expected),
      IoFailure.new,
    );
    // The rows follow the chapter into recovery, as they do in the old app,
    // so restoring it brings its schedule and history back with it.
    if (result case Deleted(:final recoveredTo)) {
      final moved = await _training.repoint(ref, DocumentRef(recoveredTo));
      return Deleted(recoveredTo, training: moved);
    }
    return result;
  }

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
    final refused = await keepReplacedVersion(
      backups: _backups,
      documents: documents,
      ref: ref,
      bytes: bytes,
      hash: revision.contentHash,
    );
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
      return IoFailure(failureDetail(error));
    }
    await _sync(folderOf(ref));
    return Deleted(target);
  }

  /// Takes back a destination folder this move created and nothing landed
  /// in, so a refused move leaves the tree exactly as it found it.
  Future<void> _removeIfMade(Directory target, bool made) async {
    if (!made) return;
    try {
      if (await target.list().isEmpty) await target.delete();
    } on FileSystemException catch (error) {
      log.w('remove the empty folder ${target.path}', error);
    }
  }

  Future<void> _sync(Directory directory) async {
    try {
      await syncDirectory(directory.path);
    } on FileSystemException catch (error) {
      log.w('flush ${directory.path}', error);
    }
  }
}

/// The old app's chapter quarantine folder; both apps delete into it.
const _recoveryFolder = '.cap-pgn-history';

const outsideRoot = 'that path is outside the documents folder';

const _unlistable = 'the folder could not be read';

/// The folder [ref] lives in, which is the scope of its lock.
Directory folderOf(DocumentRef ref) => Directory(p.dirname(ref.path));

/// Runs [action] under the lock on [folder], answering [failed] when the lock
/// cannot be taken at all. [ref] is only for the log.
Future<T> lockedForDocument<T>(
  Directory folder,
  DocumentRef ref,
  Future<T> Function() action,
  T Function(String detail) failed,
) async {
  try {
    return await withDirectoryLock(folder, action);
  } on FileSystemException catch (error) {
    log.e('take the lock on ${folder.path} for ${ref.path}', error);
    return failed(failureDetail(error));
  }
}

/// The id this document's kept versions live under, or null when the ref
/// names something outside [documents].
String? documentBackupIdFor(Directory documents, DocumentRef ref) =>
    p.isWithin(documents.path, ref.path)
    ? backupId(p.relative(ref.path, from: documents.path))
    : null;

/// Records the version about to be replaced. A version that could not be
/// kept stops the write: [IoFailure] here means the document is untouched.
Future<IoFailure?> keepReplacedVersion({
  required BackupArchive backups,
  required Directory documents,
  required DocumentRef ref,
  required List<int> bytes,
  required String hash,
}) async {
  final id = documentBackupIdFor(documents, ref);
  if (id == null) return const IoFailure(outsideRoot);
  final outcome = await backups.record(
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

String failureDetail(Object error) => error is FileSystemException
    ? error.osError?.message ?? error.message
    : '$error';
