import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Serialises document mutations in one directory against every other writer:
/// other isolates, other processes, and the old app, which runs on the same
/// profile and takes this same lock.
///
/// A SQLite write transaction is the mutex. SQLite excludes separate
/// connections whether or not they are in one process, and the operating
/// system releases the transaction when a process dies, so no stale lock file
/// and no lease expiry can ever let two writers overlap. The database stays
/// empty; only the transaction matters.
///
/// The protocol is fixed by the old app's `lib/utils/file_operation_lock.dart`
/// and may not change while both apps share a profile: the lock file is
/// `chess-auto-prep-file-locks/<FNV-1a of the resolved absolute directory
/// path>.sqlite3` under the system temporary directory, the busy timeout is zero, acquisition is
/// `BEGIN IMMEDIATE` retried every 10 ms for two minutes, and the transaction
/// is rolled back however the action ends.
///
/// Never call this while already holding the lock for the same directory: the
/// inner call waits for the outer one and fails after the deadline.
Future<T> withDirectoryLock<T>(
  Directory directory,
  Future<T> Function() action,
) async {
  final key = await _lockKey(directory);
  final ahead = _turns[key] ?? Future<void>.value();
  final mine = Completer<void>();
  _turns[key] = mine.future;
  // A failed predecessor still hands the directory on.
  await ahead.catchError((Object _) {});
  try {
    return await _whileHolding(key, action);
  } finally {
    mine.complete();
    if (identical(_turns[key], mine.future)) _turns.remove(key)?.ignore();
  }
}

/// One queue per directory, so isolate-local callers wait in turn instead of
/// spinning on SQLite. Cross-process callers still contend on the database.
final _turns = <String, Future<void>>{};

Future<T> _whileHolding<T>(String key, Future<T> Function() action) async {
  final database = _open(key);
  var held = false;
  try {
    held = await _begin(database, key);
    return await action();
  } finally {
    try {
      if (held) database.execute('ROLLBACK');
    } finally {
      database.close();
    }
  }
}

Database _open(String key) {
  try {
    final root = Directory(
      p.join(Directory.systemTemp.path, 'chess-auto-prep-file-locks'),
    );
    if (!root.existsSync()) root.createSync(recursive: true);
    final database = sqlite3.open(
      p.join(root.path, '${_stablePathHash(key)}.sqlite3'),
    );
    database.execute('PRAGMA busy_timeout = 0');
    return database;
  } on SqliteException catch (e) {
    throw FileSystemException('The lock database could not be opened: $e', key);
  }
}

Future<bool> _begin(Database database, String key) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (true) {
    try {
      database.execute('BEGIN IMMEDIATE');
      return true;
    } on SqliteException catch (e) {
      if (e.resultCode != SqlError.SQLITE_BUSY &&
          e.resultCode != SqlError.SQLITE_LOCKED) {
        throw FileSystemException('The lock could not be taken: $e', key);
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const FileSystemException(
          'Another file operation held this folder for two minutes',
        );
      }
      // Waiting, not blocking: the UI isolate keeps running meanwhile.
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

/// Two paths that name one directory must hash to one lock file, so the key
/// is absolute, normalised and, where the directory exists, symlink-resolved.
Future<String> _lockKey(Directory directory) async {
  final absolute = p.normalize(p.absolute(directory.path));
  if (!await directory.exists()) return absolute;
  return p.normalize(await directory.resolveSymbolicLinks());
}

/// FNV-1a over the UTF-8 key, so every process derives the same lock name.
String _stablePathHash(String key) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(key)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
