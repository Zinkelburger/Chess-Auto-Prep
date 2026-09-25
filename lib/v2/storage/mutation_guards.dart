/// What every mutation of a document takes before it touches the disk: the
/// directory locks that keep this app, another copy of it and the old app off
/// one folder at a time, the id a document's kept versions live under, and
/// the record of the version about to be replaced.
///
/// They live here rather than beside one of their callers because the store
/// and relocation commands must take exactly the same ones, in the same
/// order, or a save and a rename of one chapter would run side by side.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'backups.dart';
import 'document_ref.dart';
import 'file_lock.dart';
import 'pgn_document_store.dart';

const outsideRoot = 'that path is outside the documents folder';

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

/// Runs [action] under every lock a relocation needs: the documents root,
/// which is the scope the old app takes for a move, and then [folders], the
/// folders at either end of it.
///
/// Both are needed. The root is the only scope that covers both ends of a
/// move, and it is what another app renaming the same chapter takes. The
/// folders are where a create, a save and a delete take theirs: without them
/// a save could pass its revision check, stage its copy, and publish it onto
/// the name this move has meanwhile renamed away — leaving the chapter on
/// disk twice, with the training rows naming only one of them.
///
/// The root first, then the folders in path order, so two relocations can
/// never wait on each other in opposite orders. A folder that is the root, or
/// that is named twice — a rename stays in one folder — is locked once.
Future<T> lockedForRelocation<T>(
  Directory documents,
  DocumentRef ref,
  List<Directory> folders,
  Future<T> Function() action,
  T Function(String detail) failed,
) {
  final root = _lockPath(documents);
  final ordered = <String>{
    for (final folder in folders) _lockPath(folder),
  }.where((folder) => folder != root).toList()..sort();
  return lockedForDocument(
    documents,
    ref,
    () => _nested(ordered, ref, action, failed),
    failed,
  );
}

// Match file_lock.dart's identity before deduplicating: two spellings of
// Documents must not recursively acquire the same SQLite transaction.
String _lockPath(Directory directory) => p.normalize(
  directory.existsSync()
      ? directory.resolveSymbolicLinksSync()
      : p.absolute(directory.path),
);

Future<T> _nested<T>(
  List<String> folders,
  DocumentRef ref,
  Future<T> Function() action,
  T Function(String detail) failed,
) {
  if (folders.isEmpty) return action();
  return lockedForDocument(
    Directory(folders.first),
    ref,
    () => _nested(folders.sublist(1), ref, action, failed),
    failed,
  );
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
