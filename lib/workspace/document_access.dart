import 'dart:async';

import 'package:path/path.dart' as p;

/// Admission and generations for document and folder commands. Navigation
/// waits through accepted changes and rejects reads begun before a later
/// change, including time spent draining participants before storage locks.
final class DocumentAccess {
  final _versions = <String, int>{};
  final _folderVersions = <String, int>{};
  final _pending = <String, ({bool folder, Completer<void> done})>{};
  int _generation = 0;

  int versionOf(String path) {
    path = p.normalize(path);
    var latest = _versions[path] ?? 0;
    for (final entry in _folderVersions.entries) {
      if (_covers(entry.key, path) && entry.value > latest)
        latest = entry.value;
    }
    return latest;
  }

  Future<void> settled(String path) async {
    path = p.normalize(path);
    while (true) {
      final waiting = [
        for (final entry in _pending.entries)
          if (p.equals(entry.key, path) ||
              (entry.value.folder && _covers(entry.key, path)))
            entry.value.done.future,
      ];
      if (waiting.isEmpty) return;
      await Future.wait(waiting);
    }
  }

  Future<T> changing<T>(String path, Future<T> Function() work) =>
      _changing(p.normalize(path), work, folder: false);

  /// Covers every descendant, including paths not present in the catalog yet.
  /// Exact and prefix versions share one clock, so neither masks later work.
  Future<T> changingFolder<T>(String path, Future<T> Function() work) =>
      _changing(p.normalize(path), work, folder: true);

  Future<T> _changing<T>(
    String path,
    Future<T> Function() work, {
    required bool folder,
  }) async {
    for (final entry in _pending.entries) {
      if (p.equals(entry.key, path) ||
          ((folder || entry.value.folder) &&
              (_covers(entry.key, path) || _covers(path, entry.key)))) {
        throw StateError('A document command is already running for $path.');
      }
    }
    final completion = Completer<void>();
    _pending[path] = (folder: folder, done: completion);
    (folder ? _folderVersions : _versions)[path] = ++_generation;
    try {
      return await work();
    } finally {
      _pending.remove(path);
      completion.complete();
    }
  }

  bool _covers(String folder, String path) =>
      p.equals(folder, path) || p.isWithin(folder, path);
}
