import 'dart:async';

import '../../models/engine_settings.dart';
import '../../models/analysis/discovery_result.dart';
import 'engine_connection.dart';
import 'engine_worker_slot.dart';
import 'eval_worker.dart';

/// One process for interactive boards. Pausing retains its configured threads,
/// hash and network; only leaving all boards or suspending releases the process.
/// The latest search owns the worker. An old pane cannot stop a newer pane.
class BoardEngine {
  static final instance = BoardEngine();

  BoardEngine({Future<EngineConnection?> Function()? createConnection})
    : _slot = EngineWorkerSlot(createConnection: createConnection);

  final EngineWorkerSlot _slot;
  final Set<Object> _clients = {};
  Future<void>? _tail;
  final Set<Object> _searchClients = {};
  final Map<Object, void Function(DiscoveryResult)> _progress = {};
  Object? _discoveryKey;
  Future<DiscoveryResult?>? _discovery;
  int _discoveryRequest = -1;
  DiscoveryResult? _latestProgress;
  int _request = 0;
  int _lifetime = 0;
  bool _suspended = false;
  (int, int)? _preparedConfig;

  int get workerCount => _slot.hasWorker ? 1 : 0;

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final tail = _tail;
    final pending = tail == null
        ? Future<T>.sync(action)
        : tail.then((_) => action());
    _tail = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return pending;
  }

  Future<EvalWorker?> _ensure() => _slot.ensure(
    threads: EngineSettings.instance.cores,
    hashMb: EngineSettings.instance.hashMb,
  );

  /// Prepare the real configuration before the first toggle, without searching.
  Future<void> prepare(Object client) {
    _clients.add(client);
    if (_suspended) return Future.value();
    final config = (
      EngineSettings.instance.cores,
      EngineSettings.instance.hashMb,
    );
    if (_preparedConfig == config) return Future.value();
    _preparedConfig = config;
    final lifetime = _lifetime;
    return _enqueue(() async {
      try {
        if (lifetime == _lifetime && !_suspended && _clients.isNotEmpty) {
          await _ensure();
        }
      } catch (_) {
        _preparedConfig = null;
        rethrow;
      }
    });
  }

  void detach(Object client) {
    _clients.remove(client);
    pause(client);
    // A route replacement can mount its new board in this same frame.
    scheduleMicrotask(() {
      if (_clients.isEmpty) _release();
    });
  }

  /// Returns null when superseded, paused or suspended. All engine work is
  /// serialized, including the final bestmove acknowledgement after a stop.
  Future<T?> run<T>(Object owner, Future<T> Function(EvalWorker) search) {
    final request = ++_request;
    _searchClients
      ..clear()
      ..add(owner);
    _progress.clear();
    _slot.stop();
    return _enqueue(() async {
      bool current() => request == _request && !_suspended;
      if (!current()) return null;
      try {
        await _slot.waitUntilStopped();
        if (!current()) return null;
        final worker = await _ensure();
        if (!current()) return null;
        if (worker == null) throw StateError('Engine unavailable');
        final result = await search(worker);
        return current() ? result : null;
      } catch (_) {
        if (!current()) return null;
        rethrow;
      }
    });
  }

  /// Multiple views of the same board share both the search and live PVs.
  Future<DiscoveryResult?> discover(
    Object owner, {
    required String fen,
    required int depth,
    required int multiPv,
    required bool whiteToMove,
    void Function(DiscoveryResult)? onProgress,
  }) {
    final key = (
      fen,
      depth,
      multiPv,
      whiteToMove,
      EngineSettings.instance.cores,
      EngineSettings.instance.hashMb,
    );
    if (_discovery == null ||
        _discoveryKey != key ||
        _discoveryRequest != _request) {
      _latestProgress = null;
      _discovery = run(
        owner,
        (worker) => worker.runDiscovery(
          fen,
          depth,
          multiPv,
          whiteToMove,
          onProgress: (result) {
            _latestProgress = result;
            for (final entry in Map.of(_progress).entries) {
              if (_searchClients.contains(entry.key)) entry.value(result);
            }
          },
        ),
      );
      _discoveryKey = key;
      _discoveryRequest = _request;
    }
    _searchClients.add(owner);
    if (onProgress != null) {
      _progress[owner] = onProgress;
      if (_latestProgress != null) onProgress(_latestProgress!);
    }
    final request = _request;
    return _discovery!.then(
      (result) =>
          request == _request && _searchClients.contains(owner) ? result : null,
    );
  }

  void pause(Object owner) {
    _progress.remove(owner);
    if (!_searchClients.remove(owner) || _searchClients.isNotEmpty) return;
    _request++;
    _slot.stop();
  }

  void _release() {
    _lifetime++;
    _preparedConfig = null;
    _request++;
    _searchClients.clear();
    _progress.clear();
    _discovery = null;
    _latestProgress = null;
    _slot.release();
  }

  void suspend() {
    _suspended = true;
    _release();
  }

  Future<void> resume() {
    _suspended = false;
    final lifetime = _lifetime;
    return _enqueue(() async {
      if (lifetime == _lifetime && !_suspended && _clients.isNotEmpty) {
        await _ensure();
      }
    });
  }

  void dispose() {
    _suspended = false;
    _clients.clear();
    _release();
    _tail = null;
  }
}
