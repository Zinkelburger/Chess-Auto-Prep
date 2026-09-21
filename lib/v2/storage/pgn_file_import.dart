import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import 'atomic_write.dart';

/// Where a file the user browsed to is opened from.
///
/// The store keeps every version of a file by its path inside Documents, so
/// a file outside it could never be written. Rather than open such a file
/// to read and say so, it is copied into `pgn_collections` and the copy is
/// opened: the user's Downloads stay as they were, and what is on the board
/// can be edited and kept. A real boundary — it reads and writes the disk —
/// so it is an interface: [NativePgnFileImport] in the app, a scripted one
/// in tests.
abstract interface class PgnFileImport {
  /// The path to open for [path]: [path] itself when it is inside
  /// Documents, else the copy made of it.
  Future<ImportResult> insideDocuments(String path);
}

sealed class ImportResult {
  const ImportResult();
}

/// [path] is inside Documents already, or is the copy that was just made.
final class FileToOpen extends ImportResult {
  const FileToOpen(this.path, {required this.copied});

  final String path;

  /// Whether [path] is a copy made now, rather than the file asked for.
  final bool copied;
}

/// The copy could not be made, so there is nothing to open.
final class ImportFailed extends ImportResult {
  const ImportFailed(this.detail);

  final String detail;
}

final class NativePgnFileImport implements PgnFileImport {
  const NativePgnFileImport({required this.documents, required this.into});

  /// The user's Documents folder, absolute.
  final String documents;

  /// The folder copies go to, absolute: `Documents/pgn_collections`.
  final String into;

  @override
  Future<ImportResult> insideDocuments(String path) async {
    if (p.isWithin(documents, path) || p.equals(documents, path)) {
      return FileToOpen(path, copied: false);
    }
    try {
      final bytes = await File(path).readAsBytes();
      final folder = Directory(into);
      await folder.create(recursive: true);
      await removeStaleTemporaries(folder);
      final copy = await _freeName(p.basename(path));
      await createFileExclusively(copy, bytes);
      log.i('copied $path into $copy');
      return FileToOpen(copy, copied: true);
    } on Object catch (error) {
      log.e('copy $path into $into', error);
      return ImportFailed('$error');
    }
  }

  /// `name.pgn`, `name (2).pgn`, `name (3).pgn`… whichever is free first, so
  /// a second download of the same course sits beside the first rather
  /// than over it.
  Future<String> _freeName(String name) async {
    final stem = p.basenameWithoutExtension(name);
    final extension = p.extension(name).isEmpty ? '.pgn' : p.extension(name);
    var candidate = p.join(into, '$stem$extension');
    for (var n = 2; await File(candidate).exists(); n++) {
      candidate = p.join(into, '$stem ($n)$extension');
    }
    return candidate;
  }
}
