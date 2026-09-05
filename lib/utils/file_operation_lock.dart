/// Serialization shared by every durable filesystem mutation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

final Map<String, Future<void>> _directoryTails = {};

/// Runs [action] under a SQLite write transaction used solely as a mutex.
/// SQLite serializes separate connections within a process as well as across
/// processes, unlike Dart's POSIX record locks (shared by every isolate).
/// The OS releases the transaction on process death; no stale-lock deletion or
/// lease expiry can let a second writer overlap a slow first writer.
/// Do not recursively acquire the same directory. Nested domain operations
/// should use a separate domain lock and let individual files take theirs.
Future<T> withFileOperationLock<T>(
  String directory,
  Future<T> Function() action,
) async {
  var key = p.normalize(p.absolute(directory));
  final requested = Directory(key);
  if (await requested.exists()) {
    key = p.normalize(await requested.resolveSymbolicLinks());
  }
  final previous = _directoryTails[key] ?? Future<void>.value();
  final turn = Completer<void>();
  _directoryTails[key] = turn.future;

  await previous.catchError((_) {});
  Database? mutex;
  var acquired = false;
  try {
    final lockRoot = Directory(
      p.join(Directory.systemTemp.path, 'chess-auto-prep-file-locks'),
    );
    if (!await lockRoot.exists()) await lockRoot.create(recursive: true);
    final lockPath = p.join(lockRoot.path, '${_stablePathHash(key)}.sqlite3');
    mutex = sqlite3.open(lockPath);
    mutex.execute('PRAGMA busy_timeout = 0');
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (!acquired) {
      try {
        mutex.execute('BEGIN IMMEDIATE');
        acquired = true;
      } on SqliteException catch (e) {
        if (e.resultCode != SqlError.SQLITE_BUSY &&
            e.resultCode != SqlError.SQLITE_LOCKED) {
          rethrow;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw FileSystemException(
            'Timed out waiting for another file operation',
            key,
          );
        }
        // Never block the UI isolate while another isolate owns the lock.
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    return await action();
  } finally {
    try {
      if (mutex != null) {
        try {
          if (acquired) mutex.execute('ROLLBACK');
        } finally {
          mutex.close();
        }
      }
    } finally {
      turn.complete();
      if (identical(_directoryTails[key], turn.future)) {
        final removed = _directoryTails.remove(key);
        assert(removed != null);
      }
    }
  }
}

/// Deterministic FNV-1a so separate Dart processes derive the same lock name.
String _stablePathHash(String path) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(path)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
