/// Shared native filesystem checks for the concrete recovery protocols.
/// Callers own their manifests, allowed participant paths and operation locks.
library;

import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import '../diagnostics/log.dart';

/// Recovery cannot safely finish, so the caller must not read or mutate this
/// Documents domain until the retained metadata is reconciled.
final class RecoveryRequired implements Exception {
  const RecoveryRequired(this.detail);
  final String detail;

  @override
  String toString() => 'Recovery required: $detail';
}

/// A native rename cannot cross volumes. Refuse that known impossibility
/// before recording intent. The caller separately validates managed ancestry
/// and namespace ownership; no destination parents are created here.
///
/// Throws [RecoveryRequired] for what will not change by itself (another
/// volume, a source or parent that is not a plain directory or file), and
/// anything else, such as a native observation that failed, as it came: a
/// look that may succeed next time.
Future<void> requireSameFileSystem(
  String from,
  String to, {
  required bool directory,
}) async {
  for (final path in [from, to]) {
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        path.contains('\u0000')) {
      throw const RecoveryRequired(
        'Filesystem admission needs normalized absolute paths.',
      );
    }
  }
  final ({int status, int? volume}) source;
  if (directory) {
    final observed = await observeDirectory(from);
    source = (status: observed.status, volume: observed.volume);
  } else {
    final observed = await observeFile(from);
    source = (status: observed.status, volume: observed.volume);
  }
  requireObserved(source.status, from);
  if (source.status != 0 || source.volume == null) {
    throw RecoveryRequired('Cannot verify the source filesystem: $from.');
  }
  var parent = p.dirname(to);
  while (true) {
    final observed = await observeDirectory(parent);
    requireObserved(observed.status, parent);
    if (observed.status == 0 && observed.volume != null) {
      if (observed.volume != source.volume) {
        throw const RecoveryRequired('A relocation cannot cross filesystems.');
      }
      return;
    }
    final next = p.dirname(parent);
    if (observed.status != 1 || next == parent) {
      throw RecoveryRequired(
        'Cannot verify the destination filesystem: $parent.',
      );
    }
    parent = next;
  }
}

Future<bool> recoveryDirectory(
  Directory directory, {
  bool create = false,
}) async {
  var observed = await observeDirectory(directory.path);
  if (observed.status == 1) {
    if (!create) return false;
    await directory.create(recursive: true);
    await flushRecoveryDirectory(p.dirname(directory.path));
    observed = await observeDirectory(directory.path);
  }
  requireObserved(observed.status, directory.path);
  if (observed.status != 0) {
    throw RecoveryRequired(
      'Compound directory is unreadable or unsupported: ${directory.path}.',
    );
  }
  return true;
}

/// Removes the staged copy a killed write left beside [path]. A staged copy is
/// never the file itself: it holds bytes whose publication was not confirmed,
/// and every writer here restages from its own input.
///
/// A link there is removed as a link, so the next write cannot follow it
/// and truncate whatever it points at.
Future<void> discardLeftoverStage(String path) async {
  final stage = temporaryPathFor(path);
  final type = await FileSystemEntity.type(stage, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.file && type != FileSystemEntityType.link) {
    throw FileSystemException('Something other than a file is staged', stage);
  }
  await (type == FileSystemEntityType.link ? Link(stage) : File(stage))
      .delete();
  log.w('removed the staged copy a stopped write left at $stage');
}

/// The native reader's allocation limit. A journal it could not read back
/// after a restart is refused before it is written.
const journalByteLimit = 512 * 1024 * 1024;

/// Encodes [json] as a journal, refusing one the reader could not load.
List<int> encodeJournal(Map<String, Object?> json) {
  final bytes = utf8.encode(jsonEncode(json));
  if (bytes.length > journalByteLimit) {
    throw const RecoveryRequired('The operation is too large to record.');
  }
  return bytes;
}

Future<void> flushRecoveryDirectory(
  String directory, {
  Future<void> Function(String) synchronize = syncDirectory,
}) => syncDirectoryWhereSupported(directory, synchronize);

// Pin configured roots before any await. Aliases at construction are trusted;
// later resolutions only detect retargeting. Participants stay no-follow.
// Support can be absent on the first edit, so resolve its nearest existing
// ancestor without creating any directories before command validation.
Directory canonicalRecoveryRoot(Directory directory) {
  var current = p.normalize(p.absolute(directory.path));
  final absent = <String>[];
  while (FileSystemEntity.typeSync(current, followLinks: false) ==
      FileSystemEntityType.notFound) {
    absent.add(p.basename(current));
    final parent = p.dirname(current);
    if (parent == current) {
      throw RecoveryRequired(
        'The profile root cannot be resolved: ${directory.path}.',
      );
    }
    current = parent;
  }
  final resolved = Directory(current).resolveSymbolicLinksSync();
  return Directory(p.joinAll([resolved, ...absent.reversed]));
}

/// Capture before preparation creates metadata directories. Flushing through
/// this pre-existing parent persists every new entry without requiring access
/// to unrelated ancestors outside the profile's sandbox. [directory] is pinned
/// by [canonicalRecoveryRoot] first, so configured aliases keep one spelling.
String recoveryMetadataBoundary(Directory directory) {
  var current = directory.parent.path;
  while (true) {
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    if (type == FileSystemEntityType.directory) return current;
    final parent = p.dirname(current);
    if (type != FileSystemEntityType.notFound || parent == current) {
      throw RecoveryRequired('Metadata ancestry is unavailable: $current.');
    }
    current = parent;
  }
}

/// Confirm every newly reachable directory, including the entry naming it.
/// [through] includes that ancestor; omitted means all the way to the root.
Future<void> flushRecoveryAncestry(
  String directory, {
  String? through,
  Future<void> Function(String) synchronize = syncDirectory,
}) async {
  var current = directory;
  while (true) {
    await flushRecoveryDirectory(current, synchronize: synchronize);
    if (current == through || p.dirname(current) == current) return;
    current = p.dirname(current);
  }
}

/// Throws a passing [FileSystemException] when a native observation failed to
/// open or read [path] (status 2) or saw it change while reading (status 3).
/// Neither says what is there — a sync client or another app may hold it for
/// now — so recovery keeps its record for the next access rather than setting
/// it aside. A link, a non-file or an oversized file (status 4) stays decisive.
void requireObserved(int status, String path) {
  if (status == 2 || status == 3) {
    throw FileSystemException(
      'Recovery participant could not be observed (status $status)',
      path,
    );
  }
}

/// Native no-follow UTF-8 read preserving the exact byte-order mark.
Future<String?> recoveryText(String path) async {
  final file = await observeFile(path);
  if (file.status == 1) return null;
  requireObserved(file.status, path);
  if (file.status != 0 || file.bytes == null) {
    throw RecoveryRequired(
      'Recovery participant is unreadable or linked: $path.',
    );
  }
  return exactText(file.bytes!);
}

/// Writes [after] at [path] unless it is there already, when only the folder
/// is flushed; null leaves [path] as it is.
Future<void> publishText(
  String path,
  String? after, {
  Future<void> Function(String) synchronize = syncDirectory,
}) async {
  if (after == null || await recoveryText(path) == after) {
    await flushRecoveryDirectory(p.dirname(path), synchronize: synchronize);
  } else {
    await discardLeftoverStage(path);
    await replaceFile(path, utf8.encode(after));
  }
}

/// Makes [path], which the caller has just read as [current], one of the
/// snapshots an operation recorded, hold exactly its [after]: written
/// unless it holds it already, when only the folder is flushed. A null
/// [after] is the absence the operation recorded, so the file is removed.
Future<void> publishExactText(
  String path, {
  required String? current,
  required String? after,
  Future<void> Function(String) synchronize = syncDirectory,
}) async {
  if (current != after && after == null) await File(path).delete();
  if (current == after || after == null) {
    await flushRecoveryDirectory(p.dirname(path), synchronize: synchronize);
  } else {
    await discardLeftoverStage(path);
    await replaceFile(path, utf8.encode(after));
  }
}

/// Whether [bytes] open with a UTF-8 byte-order mark.
bool hasByteOrderMark(List<int> bytes) =>
    bytes.length >= 3 &&
    bytes[0] == 0xef &&
    bytes[1] == 0xbb &&
    bytes[2] == 0xbf;

/// UTF-8 text that keeps a leading byte-order mark, which [utf8] drops, so
/// comparing it with a recorded snapshot compares the exact bytes.
String exactText(List<int> bytes) {
  final text = utf8.decode(bytes);
  return hasByteOrderMark(bytes) ? '\ufeff$text' : text;
}
