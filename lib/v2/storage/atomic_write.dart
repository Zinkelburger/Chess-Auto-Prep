/// Publishing a file with the durability POSIX offers: write a complete
/// temporary file in the destination's own directory, flush it to disk, put it
/// in place with one rename, then flush the directory entry. A reader between
/// any two steps sees either the whole old file or the whole new one, and a
/// machine that loses power keeps one of them.
///
/// Every caller here holds the directory lock, so the temporary name below is
/// only ever used by one writer at a time.
///
/// This publishes bytes; it does not decide whether they may be published. A
/// document's own bytes reach it from [PgnFileStore] alone, which is where a
/// save is checked against the version it replaces. The other callers write
/// files beside a document rather than a document: kept versions and their
/// index, training rows, the note a move leaves behind.
///
/// Windows uses ReplaceFileW with bounded sharing retries and preserves the
/// existing file's metadata. macOS flushes staged bytes with F_FULLFSYNC.
/// Windows has no equivalent directory-entry flush, so that step is skipped;
/// this is not a blanket power-loss guarantee on every filesystem.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'directory_entries.dart';
import '../diagnostics/log.dart';

/// Where the staged copy of [path] lives while it is being written.
String temporaryPathFor(String path) {
  final name = p.basename(path);
  final bytes = utf8.encode(name);
  final short = bytes.length > 180 ? sha256.convert(bytes).toString() : name;
  return p.join(p.dirname(path), '.$short$_temporarySuffix');
}

const _temporarySuffix = '.v2-tmp';

/// Creates [path] and fails if the name is taken. The kernel decides the
/// winner, so two writers racing for one new name cannot both succeed.
///
/// Throws [NativeNameCollision] when the name exists.
Future<void> createFileExclusively(String path, List<int> bytes) async {
  final staged = await _stage(path, bytes);
  try {
    await installNewFile(staged.path, path);
  } on Object {
    await _discard(staged);
    rethrow;
  }
  await _syncDirectoryEntry(path);
}

/// Replaces [path] with [bytes]. The caller has already checked the revision
/// of what is being replaced and recorded it.
Future<void> replaceFile(
  String path,
  List<int> bytes, {
  void Function(NativeFileObservation)? installed,
}) async {
  final staged = await _stage(path, bytes);
  NativeFileObservation? observed;
  try {
    if (installed != null) {
      observed = await observeFile(staged.path);
      if (observed.status != 0) {
        throw FileSystemException('Cannot identify the staged document', path);
      }
    }
    await replaceFileContents(staged.path, path);
  } on Object catch (error) {
    // ReplaceFileW can report a partial namespace move. Keep both the staged
    // draft and its native recovery copy if restoring the old name failed.
    if (error is! FileSystemException ||
        !const [1176, 1177].contains(error.osError?.errorCode)) {
      await _discard(staged);
    }
    rethrow;
  }
  if (observed != null) installed!(observed);
  await _syncDirectoryEntry(path);
}

/// Removes staged copies an interrupted write left behind. They are never the
/// document: the document is only ever the name the caller asked for.
Future<void> removeStaleTemporaries(Directory directory) async {
  if (!await directory.exists()) return;
  await for (final entry in directoryEntries(directory, followLinks: false)) {
    final name = p.basename(entry.path);
    if (entry is File &&
        name.startsWith('.') &&
        name.endsWith(_temporarySuffix)) {
      await entry.delete();
    }
  }
}

/// Flushes the directory entry that now names [path]. Windows has no
/// directory handle to flush, so the native call reports not-supported there
/// and a save that succeeded would otherwise be reported as a failure.
Future<void> _syncDirectoryEntry(String path) async {
  if (Platform.isWindows) return;
  await syncDirectory(p.dirname(path));
}

/// Writes the staged copy whole. A write that fails part way — the disk is
/// full, say — takes its half-written copy with it, so what it leaves is
/// exactly what was there before: the document, untouched.
Future<File> _stage(String path, List<int> bytes) async {
  final staged = File(temporaryPathFor(path));
  final handle = await staged.open(mode: FileMode.writeOnly);
  try {
    await handle.writeFrom(bytes);
  } on Object {
    await handle.close();
    await _discard(staged);
    rethrow;
  }
  await handle.close();
  try {
    await syncFile(staged.path);
  } on Object {
    await _discard(staged);
    rethrow;
  }
  return staged;
}

Future<void> _discard(File staged) async {
  try {
    await staged.delete();
  } on FileSystemException catch (error) {
    // The write already failed; a leftover temporary is swept by the next one.
    log.w('remove the staged copy at ${staged.path}', error);
  }
}
