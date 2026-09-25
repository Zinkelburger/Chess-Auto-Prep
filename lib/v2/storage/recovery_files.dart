/// Shared native filesystem checks for the concrete recovery protocols.
/// Callers own their manifests, allowed participant paths and operation locks.
library;

import 'dart:convert';
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import '../diagnostics/log.dart';
import 'relocation_notes.dart' show RecoveryRequired;

/// A native rename cannot cross volumes. Refuse that known impossibility
/// before recording intent. The caller separately validates managed ancestry
/// and namespace ownership; no destination parents are created here.
Future<void> requireSameFileSystem(
  String from,
  String to, {
  required bool directory,
}) async {
  try {
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
    if (source.status != 0 || source.volume == null) {
      throw RecoveryRequired('Cannot verify the source filesystem: $from.');
    }
    var parent = p.dirname(to);
    while (true) {
      final observed = await observeDirectory(parent);
      if (observed.status == 0 && observed.volume != null) {
        if (observed.volume != source.volume) {
          throw const RecoveryRequired(
            'A relocation cannot cross filesystems.',
          );
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
  } on RecoveryRequired {
    rethrow;
  } on Object catch (error) {
    throw RecoveryRequired('Cannot verify relocation filesystems: $error');
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
Future<void> discardLeftoverStage(String path) async {
  final stage = File(temporaryPathFor(path));
  if (await FileSystemEntity.type(stage.path, followLinks: false) !=
      FileSystemEntityType.file) {
    return;
  }
  log.w('remove the staged copy a stopped write left at ${stage.path}');
  await stage.delete();
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
}) async {
  if (!Platform.isWindows) await synchronize(directory);
}

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

/// Native no-follow UTF-8 read preserving the exact byte-order mark.
Future<String?> recoveryText(String path) async {
  final file = await observeFile(path);
  if (file.status == 1) return null;
  if (file.status != 0 || file.bytes == null) {
    throw RecoveryRequired(
      'Recovery participant is unreadable or linked: $path.',
    );
  }
  return exactText(file.bytes!);
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
