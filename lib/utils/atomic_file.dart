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

/// The points a write passes through, in order, for failure-injection tests.
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

/// A backup-and-swap that failed *and* could not be rolled back. The original
/// content survives at [recoveryPath] and the next recovery pass restores it.
class AtomicWriteException implements IOException {
  const AtomicWriteException(this.message, {this.recoveryPath});

  final String message;
  final String? recoveryPath;

  @override
  String toString() => recoveryPath == null
      ? 'AtomicWriteException: $message'
      : 'AtomicWriteException: $message (recoverable at $recoveryPath)';
}

/// Thrown by a compare-and-swap write whose `expectedContent` no longer
/// matches the file: someone else wrote it since the caller read it.
class AtomicWriteConflict implements IOException {
  const AtomicWriteConflict(this.path);

  final String path;

  @override
  String toString() =>
      'AtomicWriteConflict: $path changed after it was read; refusing to '
      'overwrite the newer content.';
}

class AtomicNameCollision extends FileSystemException {
  const AtomicNameCollision(String path)
    : super('Destination already exists; refusing to overwrite', path);
}

/// Prefix of the journal a backup-and-swap leaves beside its target.
const _journalPrefix = '.cap-safe-write-';
const _journalSuffix = '.json';

/// Injectable only for deterministic failure tests. Production callers use
/// [writeTextFileAtomically].
class AtomicFileWriter {
  AtomicFileWriter({this.testHook, this.forceBackupSwapForTesting = false});

  final AtomicWriteHook? testHook;
  final bool forceBackupSwapForTesting;

  /// A document boundary can validate native revisions and publish while
  /// holding the same mutex used by legacy writers. The transaction is scoped
  /// to this callback; retaining it after the callback fails closed.
  Future<T> transaction<T>(
    File target,
    Future<T> Function(AtomicFileTransaction transaction) action,
  ) => withFileOperationLock(target.parent.path, () async {
    await _recoverAtomicWritesLocked(target.parent);
    final transaction = AtomicFileTransaction._(this, target);
    try {
      return await action(transaction);
    } finally {
      transaction._active = false;
      // A callback must not release the mutex while a write it started can
      // still complete, even if it forgot to await that write.
      await Future.wait(transaction._pending);
    }
  });

  /// Writes [content], keeping the file gzipped if it already was.
  ///
  /// With [expectedContent], the write only lands if the file still decodes
  /// to exactly that text; otherwise [AtomicWriteConflict] is thrown.
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
    await _writeBytesLocked(
      target,
      _encodeLike(existing, utf8.encode(content)),
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
    await _writeBytesLocked(
      target,
      _encodeLike(raw, utf8.encode(content)),
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
        List<int>? raw;
        if (await target.exists()) raw = await target.readAsBytes();
        final combined = <int>[
          if (raw != null) ...maybeGunzip(raw),
          ...utf8.encode(content),
        ];
        await _writeBytesLocked(
          target,
          _encodeLike(raw, combined),
          createOnly: false,
        );
      });

  /// [plain] gzipped when [existing] (the file's current bytes) was gzipped,
  /// so a compacted file stays compacted through every rewrite.
  static List<int> _encodeLike(List<int>? existing, List<int> plain) =>
      existing != null && looksGzipped(existing) ? gzipBytes(plain) : plain;

  Future<void> _step(AtomicWriteStep step) async {
    await testHook?.call(step);
  }

  /// Flushes [bytes] to a temporary file beside [target] and installs it,
  /// by rename where the platform allows and by journaled backup-and-swap
  /// otherwise. The caller holds the directory lock.
  Future<void> _writeBytesLocked(
    File target,
    List<int> bytes, {
    required bool createOnly,
    Future<void> Function(File staged)? validate,
    Future<void> Function(File staged, File destination)? installNew,
  }) async {
    final parent = target.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    final token = _transactionToken();
    final base = p.basename(target.path);
    final tmp = File(p.join(parent.path, '.$base.$token.tmp'));

    await tmp.writeAsBytes(bytes, flush: true);
    var keepArtifactsForRecovery = false;
    try {
      await _step(AtomicWriteStep.tempFlushed);
      await validate?.call(tmp);
      if (createOnly) {
        if (await target.exists()) {
          throw AtomicNameCollision(target.path);
        }
        if (installNew != null) {
          await installNew(tmp, target);
          await _step(AtomicWriteStep.replacementInstalled);
        } else {
          await _installByRename(tmp, target);
        }
        return;
      }
      if (!forceBackupSwapForTesting) {
        await _step(AtomicWriteStep.beforePrimaryReplace);
        try {
          await _installByRename(tmp, target);
          return;
        } on FileSystemException {
          if (!await target.exists()) rethrow;
        }
      }
      if (!await target.exists()) {
        await _installByRename(tmp, target);
        return;
      }

      final backup = File(p.join(parent.path, '.$base.$token.backup'));
      final journal = File(
        p.join(parent.path, '$_journalPrefix$token$_journalSuffix'),
      );
      await journal.writeAsString(
        jsonEncode({
          'target': base,
          'temporary': p.basename(tmp.path),
          'backup': p.basename(backup.path),
        }),
        flush: true,
      );
      // From here the journal names every artifact, so a crash leaves them
      // for [recoverAtomicWritesInDirectory] rather than deleting evidence.
      keepArtifactsForRecovery = true;
      final installFailure = await _swapThroughBackup(
        tmp,
        target,
        backup: backup,
        journal: journal,
      );
      keepArtifactsForRecovery = false;
      if (installFailure != null) {
        Error.throwWithStackTrace(
          installFailure.error,
          installFailure.stackTrace,
        );
      }
    } finally {
      if (!keepArtifactsForRecovery && await tmp.exists()) {
        await tmp.delete();
      }
    }
  }

  Future<void> _installByRename(File tmp, File target) async {
    await tmp.rename(target.path);
    await _step(AtomicWriteStep.replacementInstalled);
  }

  /// Moves [target] aside to [backup], renames [tmp] into place, then removes
  /// [backup] and [journal].
  ///
  /// When the install fails but the rollback restores [target], the install
  /// error is *returned* so the caller can discard the artifacts before
  /// rethrowing it. Anything thrown from here — the backup rename, or a
  /// rollback that failed too — leaves the artifacts in place for recovery.
  Future<({Object error, StackTrace stackTrace})?> _swapThroughBackup(
    File tmp,
    File target, {
    required File backup,
    required File journal,
  }) async {
    await _step(AtomicWriteStep.beforeBackup);
    await target.rename(backup.path);
    await _step(AtomicWriteStep.backupInstalled);

    try {
      await _step(AtomicWriteStep.beforeReplacementInstall);
      await tmp.rename(target.path);
    } catch (installError, installStack) {
      await _step(AtomicWriteStep.beforeRollback);
      try {
        if (!await target.exists() && await backup.exists()) {
          await backup.rename(target.path);
        }
        await _step(AtomicWriteStep.rollbackFinished);
        if (await journal.exists()) await journal.delete();
      } catch (rollbackError) {
        throw AtomicWriteException(
          'Replacement failed ($installError) and rollback failed '
          '($rollbackError). The original remains in the backup.',
          recoveryPath: backup.path,
        );
      }
      return (error: installError, stackTrace: installStack);
    }

    await _step(AtomicWriteStep.replacementInstalled);
    if (await backup.exists()) await backup.delete();
    if (await journal.exists()) await journal.delete();
    return null;
  }
}

/// A scoped write capability, not an independently lockable raw writer.
class AtomicFileTransaction {
  AtomicFileTransaction._(this._writer, this._target);
  final AtomicFileWriter _writer;
  final File _target;
  bool _active = true;
  final List<Future<void>> _pending = [];

  Future<void> writeBytes(
    List<int> bytes, {
    required bool createOnly,
    required Future<void> Function(File staged) validate,
    Future<void> Function(File staged, File destination)? installNew,
  }) {
    if (!_active) throw StateError('File transaction has ended');
    final operation = _writer._writeBytesLocked(
      _target,
      bytes,
      createOnly: createOnly,
      validate: validate,
      installNew: installNew,
    );
    // Observe errors for the drain without changing the caller's result.
    _pending.add(
      operation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return operation;
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
}) => _defaultWriter.writeText(
  target,
  content,
  createOnly: createOnly,
  expectedContent: expectedContent,
);

/// See [AtomicFileWriter.appendText].
Future<void> appendTextFileAtomically(File target, String content) =>
    _defaultWriter.appendText(target, content);

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

/// Whether [file] exists once any interrupted write beside it is repaired.
Future<bool> textFileExistsSafely(File file) =>
    withFileOperationLock(file.parent.path, () async {
      await _recoverAtomicWritesLocked(file.parent);
      return file.exists();
    });

/// See [AtomicFileWriter.updateText].
Future<String> updateTextFileAtomically(
  File file,
  FutureOr<String> Function(String? current) update,
) => _defaultWriter.updateText(file, update);

/// The three files a backup-and-swap journal names, all basenames inside the
/// journal's own directory.
typedef _SwapJournal = ({String target, String temporary, String backup});

/// Decodes [journalFile], or null when its content is not a journal this
/// writer produced for the token in its own filename.
Future<_SwapJournal?> _readSwapJournal(File journalFile) async {
  final name = p.basename(journalFile.path);
  final token = name.substring(
    _journalPrefix.length,
    name.length - _journalSuffix.length,
  );
  final decoded = jsonDecode(await journalFile.readAsString());
  if (decoded is! Map<String, dynamic>) return null;
  final target = decoded['target'];
  final temporary = decoded['temporary'];
  final backup = decoded['backup'];
  if (target is! String ||
      temporary is! String ||
      backup is! String ||
      p.basename(target) != target ||
      temporary != '.$target.$token.tmp' ||
      backup != '.$target.$token.backup') {
    return null;
  }
  return (target: target, temporary: temporary, backup: backup);
}

Future<void> _recoverAtomicWritesLocked(Directory directory) async {
  if (!await directory.exists()) return;
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    if (!name.startsWith(_journalPrefix) || !name.endsWith(_journalSuffix)) {
      continue;
    }
    try {
      final journal = await _readSwapJournal(entity);
      if (journal == null) continue;
      final target = File(p.join(directory.path, journal.target));
      final temporary = File(p.join(directory.path, journal.temporary));
      final backup = File(p.join(directory.path, journal.backup));
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
