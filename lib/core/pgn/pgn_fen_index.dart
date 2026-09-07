/// Precomputed FEN → game-indices map for the PGN viewer, extracted from
/// `PgnViewerController`.
///
/// Owns the index value, its build generation, and the persistence IO
/// (`<pgn>.fenidx`). `PgnViewerController` keeps its public `fenIndex` getter
/// and delegates here, so existing call-sites are unchanged.
library;

import '../../utils/isolate_task.dart';

import 'package:flutter/foundation.dart';

import '../../services/pgn_parsing_service.dart' as pgn;
import '../../services/storage/storage_factory.dart';

class PgnFenIndex {
  PgnFenIndex({required this.isActive, required this.onChanged});

  /// Whether the owning view is still mounted/active.
  final bool Function() isActive;

  /// Notify listeners (the controller's `notifyListeners`).
  final VoidCallback onChanged;

  Map<String, List<int>>? _value;
  int _generation = 0;
  IsolateTask? _task;

  /// Set when the PGN file was rewritten after [value] was persisted: the
  /// companion file's size/mtime stamp no longer matches, so it would be
  /// rejected on the next load.  Cleared by [flushIfStale].
  bool _stale = false;

  /// Read-only access to the precomputed FEN → game-indices map.
  /// Returns null while the index is being built.
  Map<String, List<int>>? get value => _value;

  /// Stop unfinished work without dropping the index owed to a pending save.
  void cancel() {
    _generation++;
    _task?.cancel();
  }

  /// Drop the current index and invalidate work for the outgoing collection.
  /// A still-running load/build must never install the old file's indices
  /// against the new file's games.
  void reset() {
    cancel();
    _value = null;
    _stale = false;
  }

  /// Note that the PGN file changed under the persisted index (a comment or
  /// rating write).  Persisting the index after every such write re-serialised
  /// the whole map per keystroke burst; instead it is written once, by
  /// [flushIfStale], when the collection is closed.
  void markStale() => _stale = true;

  /// Persist the index if a file write left it stale.  Safe to call when the
  /// collection is being replaced: the index is captured synchronously, so a
  /// [reset] that follows immediately does not empty it under the write.
  Future<void> flushIfStale({
    required String? filePath,
    required int gameTotal,
  }) {
    if (!_stale || _value == null || filePath == null) return Future.value();
    _stale = false;
    return _persistIndex(_value!, filePath: filePath, gameTotal: gameTotal);
  }

  /// Try to load a persisted `<pgn>.fenidx` companion file, validating it
  /// against the current file's stats. Leaves [value] null on any mismatch.
  Future<void> tryLoadPersisted(String pgnPath, int gameCount) async {
    final generation = _generation;
    _task?.cancel();
    final task = _task = IsolateTask();
    try {
      final storage = StorageFactory.instance;
      final stat = await storage.fileStat(pgnPath);
      if (stat == null) return;

      final idxPath = '$pgnPath.fenidx';
      if (!await storage.fileExists(idxPath)) return;
      final data = await storage.readFile(idxPath);
      if (data == null || data.isEmpty) return;
      if (!isActive() || task.isCancelled || generation != _generation) return;
      final index = await task.run(
        (_) => pgn.deserializeFenIndex(
          data,
          expectedGameCount: gameCount,
          expectedFileSize: stat.size,
          expectedModifiedMs: stat.modified.millisecondsSinceEpoch,
        ),
      );
      if (index == null) return;
      // A reset() (new file) may have happened during the reads above —
      // installing this index would hand the new file the old file's index.
      if (!isActive() || task.isCancelled || generation != _generation) return;
      _value = index;
    } catch (_) {
      // Corrupt or unreadable — fall through to building from scratch.
    }
  }

  /// Build the index from [gameData] in a background isolate, then persist it.
  Future<void> build(
    List<({Map<String, String> headers, String pgnText})> gameData, {
    required String? filePath,
    required int gameTotal,
  }) async {
    final generation = ++_generation;
    _value = null;

    _task?.cancel();
    final task = _task = IsolateTask();
    final Map<String, List<int>> index;
    try {
      index = await task.run((_) => pgn.buildFenIndex(gameData));
    } on IsolateTaskCancelled {
      return;
    }
    if (!isActive() || task.isCancelled || generation != _generation) return;

    _value = index;
    onChanged();
    await persist(filePath: filePath, gameTotal: gameTotal);
  }

  /// Persist the current index to the `<pgn>.fenidx` companion file.
  Future<void> persist({required String? filePath, required int gameTotal}) {
    final index = _value;
    if (filePath == null || index == null) return Future.value();
    _stale = false;
    return _persistIndex(index, filePath: filePath, gameTotal: gameTotal);
  }

  Future<void> _persistIndex(
    Map<String, List<int>> index, {
    required String filePath,
    required int gameTotal,
  }) async {
    try {
      final storage = StorageFactory.instance;
      final stat = await storage.fileStat(filePath);
      if (stat == null) return;
      final data = await IsolateTask().run(
        (_) => _serializeValidIndex(
          index,
          gameTotal,
          stat.size,
          stat.modified.millisecondsSinceEpoch,
        ),
      );
      if (data == null) return;
      await storage.writeFile('$filePath.fenidx', data);
    } catch (e) {
      debugPrint('Failed to persist FEN index: $e');
    }
  }
}

String? _serializeValidIndex(
  Map<String, List<int>> index,
  int gameCount,
  int fileSize,
  int modifiedMs,
) {
  for (final indices in index.values) {
    if (indices.any((i) => i < 0 || i >= gameCount)) return null;
  }
  return pgn.serializeFenIndex(
    index,
    gameCount: gameCount,
    fileSize: fileSize,
    modifiedMs: modifiedMs,
  );
}
