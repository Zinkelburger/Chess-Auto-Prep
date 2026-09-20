/// Where a document lives: renaming it, moving it to another folder, and
/// deleting it, which is a move into the recovery folder.
///
/// These mutations change the name rather than the bytes, so they end in a
/// rename on disk rather than a publication. They take the same guards the
/// store's create and save take, in `mutation_guards.dart`, and each of them
/// is two writes rather than one: the rename, and the training rows that
/// name the file. [PendingRepoints] is what makes the pair survive a machine
/// that stops between them.
library;

import 'dart:io';
import 'dart:math';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'backups.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'mutation_guards.dart';
import 'pending_repoint.dart';
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
    required PendingRepoints unfinished,
  }) : _backups = backups,
       _training = records,
       _unfinished = unfinished;

  /// The folder every document lives under; a ref outside it is refused.
  final Directory documents;

  final BackupArchive _backups;
  final training.TrainingRecords _training;
  final PendingRepoints _unfinished;

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

  /// Moving holds the documents root, because that is the scope the old app
  /// takes for the same operation (`io_storage_service.dart`, `_rootForMove`)
  /// and no one folder covers both ends of a move, and both folders, because
  /// that is where a save takes its lock. See [lockedForRelocation].
  ///
  /// The training rows are rewritten inside those locks, so nothing else
  /// moves this chapter while half of the move is done.
  Future<MoveResult> move(
    DocumentRef ref,
    DocumentRef destination, {
    required Revision expected,
  }) => lockedForRelocation(
    documents,
    ref,
    [folderOf(ref), folderOf(destination)],
    () => _moveAndRepoint(ref, destination, expected),
    IoFailure.new,
  );

  Future<MoveResult> _moveAndRepoint(
    DocumentRef ref,
    DocumentRef destination,
    Revision expected,
  ) async {
    await _finishUnfinishedMove();
    final result = await _move(ref, destination, expected);
    if (result case Moved(:final revision)) {
      return Moved(revision, training: await _repoint(ref, destination));
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
      await _unfinished.record(ref.path, destination.path);
      await movePathNoReplace(ref.path, destination.path);
    } on NativeNameCollision {
      await _unfinished.clear();
      await _removeIfMade(target, made);
      return const Collision();
    } on Object catch (error) {
      log.e('move ${ref.path}', error);
      await _unfinished.clear();
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
  Future<FolderMoveResult> moveFolder(String from, String to) =>
      lockedForRelocation(
        documents,
        DocumentRef(from),
        [Directory(from), Directory(to)],
        () => _moveFolderAndRepoint(from, to),
        FolderMoveFailed.new,
      );

  /// `repoint` rewrites every row inside a folder that moved, not just the
  /// rows that name it exactly.
  Future<FolderMoveResult> _moveFolderAndRepoint(String from, String to) async {
    await _finishUnfinishedMove();
    final result = await _moveFolder(from, to);
    if (result is FolderMoved) {
      return FolderMoved(
        training: await _repoint(DocumentRef(from), DocumentRef(to)),
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
      await _unfinished.record(from, to);
      await movePathNoReplace(from, to);
    } on NativeNameCollision {
      await _unfinished.clear();
      return const FolderNameTaken();
    } on Object catch (error) {
      log.e('move the folder $from', error);
      await _unfinished.clear();
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
  Future<DeleteResult> delete(DocumentRef ref, {required Revision expected}) =>
      lockedForRelocation(
        documents,
        ref,
        [folderOf(ref)],
        () => _deleteAndRepoint(ref, expected),
        IoFailure.new,
      );

  /// The rows follow the chapter into recovery, as they do in the old app, so
  /// restoring it brings its schedule and history back with it.
  Future<DeleteResult> _deleteAndRepoint(
    DocumentRef ref,
    Revision expected,
  ) async {
    await _finishUnfinishedMove();
    final result = await _delete(ref, expected);
    if (result case Deleted(:final recoveredTo)) {
      final moved = await _repoint(ref, DocumentRef(recoveredTo));
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
      await _unfinished.record(ref.path, target);
      await movePathNoReplace(ref.path, target);
    } on Object catch (error) {
      log.e('delete ${ref.path}', error);
      await _unfinished.clear();
      return IoFailure(failureDetail(error));
    }
    await _sync(folderOf(ref));
    return Deleted(target);
  }

  /// Rewrites the training rows that named [from] and, once they owe
  /// nothing, takes away the note that says this move is half done.
  Future<training.RepointResult> _repoint(
    DocumentRef from,
    DocumentRef to,
  ) async {
    final result = await _training.repoint(from, to);
    if (_rowsSettled(result)) await _unfinished.clear();
    return result;
  }

  /// Finishes the rows a move that stopped half way still owes, before this
  /// relocation moves anything else. A note that cannot be honoured stays
  /// where it is: the rows are genuinely still pointing at the old name.
  Future<void> _finishUnfinishedMove() async {
    final move = await _unfinished.read();
    if (move == null) return;
    final result = await _repoint(DocumentRef(move.from), DocumentRef(move.to));
    if (_rowsSettled(result)) return;
    log.w('finish the training rows left behind by moving ${move.from}');
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

/// Whether the training rows still owe this move anything.
bool _rowsSettled(training.RepointResult result) =>
    result is training.Repointed || result is training.NothingToRepoint;

/// The old app's chapter quarantine folder; both apps delete into it.
const _recoveryFolder = '.cap-pgn-history';

const _unlistable = 'the folder could not be read';
