/// Precomputed FEN → game-indices map for the PGN viewer, extracted from
/// `PgnViewerController`.
///
/// Owns the index value, its build generation, and the persistence IO
/// (`<pgn>.fenidx`). `PgnViewerController` keeps its public `fenIndex` getter
/// and delegates here, so existing call-sites are unchanged.
library;

import 'dart:isolate';

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

  /// Read-only access to the precomputed FEN → game-indices map.
  /// Returns null while the index is being built.
  Map<String, List<int>>? get value => _value;

  /// Try to load a persisted `<pgn>.fenidx` companion file, validating it
  /// against the current file's stats. Leaves [value] null on any mismatch.
  Future<void> tryLoadPersisted(String pgnPath, int gameCount) async {
    try {
      final storage = StorageFactory.instance;
      final stat = await storage.fileStat(pgnPath);
      if (stat == null) return;

      final idxPath = '$pgnPath.fenidx';
      if (!await storage.fileExists(idxPath)) return;
      final data = await storage.readFile(idxPath);
      if (data == null || data.isEmpty) return;
      final index = pgn.deserializeFenIndex(
        data,
        expectedGameCount: gameCount,
        expectedFileSize: stat.size,
        expectedModifiedMs: stat.modified.millisecondsSinceEpoch,
      );
      if (index == null) return;
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

    final index = await Isolate.run(() => pgn.buildFenIndex(gameData));
    if (!isActive() || generation != _generation) return;

    _value = index;
    onChanged();
    await persist(filePath: filePath, gameTotal: gameTotal);
  }

  /// Persist the current index to the `<pgn>.fenidx` companion file.
  Future<void> persist({
    required String? filePath,
    required int gameTotal,
  }) async {
    if (filePath == null || _value == null) return;
    // Guard against persisting an index that is inconsistent with [gameTotal]:
    // the header records [gameTotal] as the game count, so any stored index
    // outside `[0, gameTotal)` would produce a file that passes load-time
    // validation yet points past `allGames`, crashing consumers with a
    // RangeError. If the in-memory index and [gameTotal] disagree, skip the
    // write rather than persist a corrupt companion file.
    for (final indices in _value!.values) {
      for (final i in indices) {
        if (i < 0 || i >= gameTotal) {
          debugPrint('Skipping FEN index persist: index $i out of range for '
              '$gameTotal games (stale index vs. game set).');
          return;
        }
      }
    }
    try {
      final storage = StorageFactory.instance;
      final stat = await storage.fileStat(filePath);
      if (stat == null) return;
      final data = pgn.serializeFenIndex(
        _value!,
        gameCount: gameTotal,
        fileSize: stat.size,
        modifiedMs: stat.modified.millisecondsSinceEpoch,
      );
      await storage.writeFile('$filePath.fenidx', data);
    } catch (e) {
      debugPrint('Failed to persist FEN index: $e');
    }
  }
}
