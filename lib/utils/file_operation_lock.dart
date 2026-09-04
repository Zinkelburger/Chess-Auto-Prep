/// Serialization shared by every durable filesystem mutation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final Map<String, Future<void>> _directoryTails = {};

/// Runs [action] with both an isolate-local queue and an advisory OS lock for
/// [directory]. All app writers use the same hidden lock file, so two isolates
/// or two app processes cannot interleave a check-and-commit sequence.
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
  RandomAccessFile? handle;
  try {
    final lockRoot = Directory(
      p.join(Directory.systemTemp.path, 'chess-auto-prep-file-locks'),
    );
    if (!await lockRoot.exists()) await lockRoot.create(recursive: true);
    final lock = File(p.join(lockRoot.path, '${_stablePathHash(key)}.lock'));
    handle = await lock.open(mode: FileMode.append);
    await handle.lock(FileLock.exclusive);
    return await action();
  } finally {
    if (handle != null) {
      try {
        await handle.unlock();
      } finally {
        await handle.close();
      }
    }
    turn.complete();
    if (identical(_directoryTails[key], turn.future)) {
      final removed = _directoryTails.remove(key);
      assert(removed != null);
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
