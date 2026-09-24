import 'dart:async';

/// Admission and generations for closed-file commands. Navigation waits for
/// accepted changes and discards reads begun before a later command, including
/// time spent draining other participants before the storage locks are taken.
final class DocumentAccess {
  final _versions = <String, int>{};
  final _pending = <String, Completer<void>>{};

  int versionOf(String path) => _versions[path] ?? 0;

  Future<void> settled(String path) async {
    while (_pending[path] != null) {
      await _pending[path]!.future;
    }
  }

  Future<T> changing<T>(String path, Future<T> Function() work) async {
    if (_pending.containsKey(path)) {
      throw StateError('A document command is already running for $path.');
    }
    final completion = _pending[path] = Completer<void>();
    _versions[path] = versionOf(path) + 1;
    try {
      return await work();
    } finally {
      _pending.remove(path);
      completion.complete();
    }
  }
}
