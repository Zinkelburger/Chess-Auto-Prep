/// Failure-safe text-file writes, shared by every service that persists data.
///
/// The normal commit is a same-directory atomic rename. Platforms that cannot
/// rename over an existing destination use a journaled backup-and-swap with
/// rollback; the last valid copy is never deliberately deleted first.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'file_operation_lock.dart';
import 'file_text_reader.dart';
import 'pgn_compression.dart';

enum AtomicWriteStep {
  tempFlushed,
  beforePrimaryReplace,
  beforeBackup,
  backupInstalled,
  beforeReplacementInstall,
  replacementInstalled,
  beforeRollback,
  rollbackFinished,
}

typedef AtomicWriteHook = Future<void> Function(AtomicWriteStep step);

class AtomicWriteException implements IOException {
  const AtomicWriteException(this.message, {this.recoveryPath});

  final String message;
  final String? recoveryPath;

  @override
  String toString() => recoveryPath == null
      ? 'AtomicWriteException: $message'
      : 'AtomicWriteException: $message (recoverable at $recoveryPath)';
}

class AtomicWriteConflict implements IOException {
  const AtomicWriteConflict(this.path);

  final String path;

  @override
  String toString() =>
      'AtomicWriteConflict: $path changed after it was read; refusing to '
      'overwrite the newer content.';
}

/// Injectable only for deterministic failure tests. Production callers use
/// [writeTextFileAtomically].
class AtomicFileWriter {
  AtomicFileWriter({this.testHook, this.forceBackupSwapForTesting = false});

  final AtomicWriteHook? testHook;
  final bool forceBackupSwapForTesting;

  Future<void> writeText(
    File target,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) => withFileOperationLock(target.parent.path, () async {
    await _recoverAtomicWritesLocked(target.parent);
    List<int>? existing;
    if (await target.exists()) existing = await target.readAsBytes();
    if (expectedContent != null) {
      final current = existing == null
          ? null
          : decodeTextBytes(maybeGunzip(existing));
      if (current != expectedContent) throw AtomicWriteConflict(target.path);
    }
    final bytes = utf8.encode(content);
    await _writeBytesLocked(
      target,
      existing != null && looksGzipped(existing) ? gzipBytes(bytes) : bytes,
      createOnly: createOnly,
    );
  });

  /// Reads and transforms the current file while holding its write lock.
  /// The callback must not recursively write another file in this directory.
  Future<String> updateText(
    File target,
    FutureOr<String> Function(String? current) update,
  ) => withFileOperationLock(target.parent.path, () async {
    await _recoverAtomicWritesLocked(target.parent);
    final raw = await target.exists() ? await target.readAsBytes() : null;
    final current = raw == null ? null : decodeTextBytes(maybeGunzip(raw));
    final content = await update(current);
    final bytes = utf8.encode(content);
    await _writeBytesLocked(
      target,
      raw != null && looksGzipped(raw) ? gzipBytes(bytes) : bytes,
      createOnly: false,
    );
    return content;
  });

  Future<void> writeBytes(
    File target,
    List<int> bytes, {
    bool createOnly = false,
  }) => withFileOperationLock(target.parent.path, () async {
    await _recoverAtomicWritesLocked(target.parent);
    await _writeBytesLocked(target, bytes, createOnly: createOnly);
  });

  /// Appends [content] without exposing a partially appended file. The read and
  /// replacement share the same directory lock, so cooperating writers cannot
  /// lose one another's batch.
  Future<void> appendText(File target, String content) =>
      withFileOperationLock(target.parent.path, () async {
        await _recoverAtomicWritesLocked(target.parent);
        var existing = <int>[];
        var compressed = false;
        if (await target.exists()) {
          final raw = await target.readAsBytes();
          compressed = looksGzipped(raw);
          existing = maybeGunzip(raw);
        }
        final combined = <int>[...existing, ...utf8.encode(content)];
        await _writeBytesLocked(
          target,
          compressed ? gzipBytes(combined) : combined,
          createOnly: false,
        );
      });

  Future<void> _step(AtomicWriteStep step) async {
    await testHook?.call(step);
  }

  Future<void> _writeBytesLocked(
    File target,
    List<int> bytes, {
    required bool createOnly,
  }) async {
    final parent = target.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    final token = _transactionToken();
    final base = p.basename(target.path);
    final tmp = File(p.join(parent.path, '.$base.$token.tmp'));
    final backup = File(p.join(parent.path, '.$base.$token.backup'));
    final journal = File(p.join(parent.path, '.cap-safe-write-$token.json'));

    await tmp.writeAsBytes(bytes, flush: true);
    await _step(AtomicWriteStep.tempFlushed);

    var keepArtifactsForRecovery = false;
    try {
      if (createOnly) {
        if (await target.exists()) {
          throw FileSystemException(
            'Destination already exists; refusing to overwrite',
            target.path,
          );
        }
        await tmp.rename(target.path);
        await _step(AtomicWriteStep.replacementInstalled);
        return;
      }
      if (!forceBackupSwapForTesting) {
        await _step(AtomicWriteStep.beforePrimaryReplace);
        try {
          await tmp.rename(target.path);
          await _step(AtomicWriteStep.replacementInstalled);
          return;
        } on FileSystemException {
          if (!await target.exists()) rethrow;
        }
      }

      if (!await target.exists()) {
        await tmp.rename(target.path);
        await _step(AtomicWriteStep.replacementInstalled);
        return;
      }

      await journal.writeAsString(
        jsonEncode({
          'target': base,
          'temporary': p.basename(tmp.path),
          'backup': p.basename(backup.path),
        }),
        flush: true,
      );
      keepArtifactsForRecovery = true;
      await _step(AtomicWriteStep.beforeBackup);
      await target.rename(backup.path);
      await _step(AtomicWriteStep.backupInstalled);

      try {
        await _step(AtomicWriteStep.beforeReplacementInstall);
        await tmp.rename(target.path);
      } catch (installError) {
        await _step(AtomicWriteStep.beforeRollback);
        try {
          if (!await target.exists() && await backup.exists()) {
            await backup.rename(target.path);
          }
          await _step(AtomicWriteStep.rollbackFinished);
          keepArtifactsForRecovery = false;
          if (await journal.exists()) await journal.delete();
        } catch (rollbackError) {
          throw AtomicWriteException(
            'Replacement failed ($installError) and rollback failed '
            '($rollbackError). The original remains in the backup.',
            recoveryPath: backup.path,
          );
        }
        rethrow;
      }

      await _step(AtomicWriteStep.replacementInstalled);
      if (await backup.exists()) await backup.delete();
      if (await journal.exists()) await journal.delete();
      keepArtifactsForRecovery = false;
    } finally {
      if (!keepArtifactsForRecovery && await tmp.exists()) {
        await tmp.delete();
      }
    }
  }
}

final AtomicFileWriter _defaultWriter = AtomicFileWriter();

/// Safe for callers in any isolate. A per-isolate queue and an advisory OS
/// lock serialize cooperating writers across isolates and app processes.
///
/// A file that is *already* gzipped stays gzipped: the app reads both forms
/// transparently (see `pgn_compression.dart`), so rewriting a compacted file
/// as plain text would silently undo the user's saving the first time they
/// edited it.
Future<void> writeTextFileAtomically(
  File target,
  String content, {
  bool createOnly = false,
  String? expectedContent,
}) async {
  await _defaultWriter.writeText(
    target,
    content,
    createOnly: createOnly,
    expectedContent: expectedContent,
  );
}

Future<void> appendTextFileAtomically(File target, String content) async {
  await _defaultWriter.appendText(target, content);
}

/// Replace [target] with a gzipped copy of its own contents.
///
/// Returns the fraction of the file saved, or 0 when it was already
/// compressed or would not shrink — in which case the file is left alone.
Future<double> compactTextFile(File target) =>
    withFileOperationLock(target.parent.path, () async {
      await _recoverAtomicWritesLocked(target.parent);
      if (!await target.exists()) return 0.0;
      final raw = await target.readAsBytes();
      if (looksGzipped(raw)) return 0;
      final packed = gzipBytes(raw);
      final saving = compressionSavingOf(raw, packed);
      if (saving <= 0) return 0;
      await _defaultWriter._writeBytesLocked(target, packed, createOnly: false);
      return saving;
    });

/// Undo [compactTextFile], leaving plain text on disk.
Future<bool> expandTextFile(File target) =>
    withFileOperationLock(target.parent.path, () async {
      await _recoverAtomicWritesLocked(target.parent);
      if (!await target.exists()) return false;
      final raw = await target.readAsBytes();
      if (!looksGzipped(raw)) return false;
      await _defaultWriter._writeBytesLocked(
        target,
        maybeGunzip(raw),
        createOnly: false,
      );
      return true;
    });

String _transactionToken() {
  final random = Random.secure();
  return '${pid.toRadixString(16)}-'
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-'
      '${random.nextInt(1 << 32).toRadixString(16)}';
}

/// Repairs interrupted backup-and-swap transactions in [directory]. A journal
/// is deliberately self-contained and accepts basenames only, so corrupt or
/// malicious journal content cannot escape the directory being recovered.
Future<void> recoverAtomicWritesInDirectory(Directory directory) =>
    withFileOperationLock(
      directory.path,
      () => _recoverAtomicWritesLocked(directory),
    );

/// A read participates in recovery under the writer's lock; null means absent,
/// never unreadable. Callers must not turn a failed read into a new document.
Future<String?> readTextFileSafely(File file) =>
    withTextFileSnapshot(file, (text) async => text);

/// Holds a recovered source stable while a derived index is built. [action]
/// must not acquire this file's directory lock again.
Future<T> withTextFileSnapshot<T>(
  File file,
  Future<T> Function(String? text) action,
) => withFileOperationLock(file.parent.path, () async {
  await _recoverAtomicWritesLocked(file.parent);
  final text = await file.exists() ? await readTextFile(file) : null;
  return action(text);
});

Future<bool> textFileExistsSafely(File file) =>
    withFileOperationLock(file.parent.path, () async {
      await _recoverAtomicWritesLocked(file.parent);
      return file.exists();
    });

Future<String> updateTextFileAtomically(
  File file,
  FutureOr<String> Function(String? current) update,
) => _defaultWriter.updateText(file, update);

Future<void> _recoverAtomicWritesLocked(Directory directory) async {
  if (!await directory.exists()) return;
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    if (!name.startsWith('.cap-safe-write-') || !name.endsWith('.json')) {
      continue;
    }
    try {
      final decoded = jsonDecode(await entity.readAsString());
      if (decoded is! Map<String, dynamic>) continue;
      final targetName = decoded['target'];
      final temporaryName = decoded['temporary'];
      final backupName = decoded['backup'];
      final token = name.substring(
        '.cap-safe-write-'.length,
        name.length - '.json'.length,
      );
      if (targetName is! String ||
          temporaryName is! String ||
          backupName is! String ||
          p.basename(targetName) != targetName ||
          temporaryName != '.$targetName.$token.tmp' ||
          backupName != '.$targetName.$token.backup') {
        continue;
      }
      final target = File(p.join(directory.path, targetName));
      final temporary = File(p.join(directory.path, temporaryName));
      final backup = File(p.join(directory.path, backupName));
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      if (await target.exists()) {
        if (await backup.exists()) await backup.delete();
        if (await temporary.exists()) await temporary.delete();
        await entity.delete();
      }
    } on FileSystemException {
      // Leave every artifact in place. The next read/write can retry recovery.
    } on FormatException {
      // An unparseable journal is never permission to touch neighboring files.
    }
  }
}
