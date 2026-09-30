import 'dart:io';
import 'dart:isolate';

import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../chess/pgn/chapter.dart' show readOffThreadFrom;
import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'document_text.dart';
import 'file_lock.dart';
import 'recovery_gate.dart';

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

  /// The text of [path], read where it is and written nowhere: for an
  /// import that files the text under a name of its own, so a copy in
  /// `pgn_collections` would be one more file nobody asked for.
  Future<PickedRead> read(String path);
}

sealed class PickedRead {
  const PickedRead();
}

/// What [path] holds, decoded as the store decodes a file.
final class PickedText extends PickedRead {
  const PickedText(this.text, {this.foreignEncoding});

  final String text;

  /// Why [text] must not be written back as it came — it was not UTF-8, so
  /// reading it took a guess — or null when it may be.
  final String? foreignEncoding;
}

/// The file could not be read, or is not text.
final class PickedUnread extends PickedRead {
  const PickedUnread(this.detail);

  final String detail;
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
  const NativePgnFileImport({
    required this.documents,
    required this.into,
    required RecoveryGate recovery,
  }) : _recovery = recovery;

  final RecoveryGate _recovery;

  /// The user's Documents folder, absolute.
  final String documents;

  /// The folder copies go to, absolute: `Documents/pgn_collections`.
  final String into;

  @override
  Future<ImportResult> insideDocuments(String path) async {
    try {
      return await _recovery.run(() => _insideDocuments(path));
    } on Object catch (error) {
      log.e('copy $path into $into', error);
      return ImportFailed('$error');
    }
  }

  @override
  Future<PickedRead> read(String path) async {
    try {
      return await _recovery.run(() async {
        final bytes = await File(path).readAsBytes();
        final decoded = bytes.length < readOffThreadFrom
            ? readDocumentText(bytes)
            : await Isolate.run(() => readDocumentText(bytes));
        return switch (decoded) {
          PlainText(:final text) => PickedText(text),
          ForeignText(:final text, :final detail) => PickedText(
            text,
            foreignEncoding: detail,
          ),
          NotText(:final detail) => PickedUnread(detail),
        };
      });
    } on Object catch (error) {
      log.e('read $path', error);
      return PickedUnread('$error');
    }
  }

  Future<ImportResult> _insideDocuments(String path) async {
    if (p.isWithin(documents, path) || p.equals(documents, path)) {
      return FileToOpen(path, copied: false);
    }
    try {
      final bytes = await File(path).readAsBytes();
      final folder = Directory(into);
      await folder.create(recursive: true);
      // The folder's lock, which a save of a file already in it takes too:
      // each sweeps staged copies before writing its own, and without it
      // one would delete the copy the other is about to put in place.
      final copy = await withDirectoryLock(folder, () async {
        await removeStaleTemporaries(folder);
        return _copyUnderFreeName(p.basename(path), bytes);
      });
      log.i('copied $path into $copy');
      return FileToOpen(copy, copied: true);
    } on Object catch (error) {
      log.e('copy $path into $into', error);
      return ImportFailed('$error');
    }
  }

  /// Writes [bytes] as `name.pgn`, `name (2).pgn`, `name (3).pgn`…
  /// whichever is free first, so a second download of the same course sits
  /// beside the first rather than over it. A name taken between the look and
  /// the write — by a program that does not take the lock — moves on to the
  /// next one.
  Future<String> _copyUnderFreeName(String name, List<int> bytes) async {
    final stem = p.basenameWithoutExtension(name);
    final extension = p.extension(name).isEmpty ? '.pgn' : p.extension(name);
    for (var n = 1; ; n++) {
      final candidate = p.join(
        into,
        n == 1 ? '$stem$extension' : '$stem ($n)$extension',
      );
      if (await File(candidate).exists()) continue;
      try {
        await createFileExclusively(candidate, bytes);
        return candidate;
      } on NativeNameCollision {
        log.w('copy into $candidate', 'the name was taken meanwhile');
      }
    }
  }
}
