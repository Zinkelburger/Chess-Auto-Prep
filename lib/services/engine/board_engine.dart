import 'dart:async';

import '../../models/engine_settings.dart';
import '../../models/analysis/discovery_result.dart';
import 'engine_connection.dart';
import 'engine_worker_slot.dart';
import 'eval_worker.dart';
import 'engine_search_budget.dart';
import 'engine_serial_queue.dart';

/// One process for interactive boards. Pausing retains its configured threads,
/// hash and network; only leaving all boards or suspending releases the process.
/// The latest search owns the worker. An old pane cannot stop a newer pane.
class BoardEngine {
  static final instance = BoardEngine();

  BoardEngine({
    Future<EngineConnection?> Function()? createConnection,
    EngineSearchBudget? budget,
    Duration protocolTimeout = const Duration(seconds: 10),
  }) : _slot = EngineWorkerSlot(
         createConnection: createConnection,
         budget: budget,
         protocolTimeout: protocolTimeout,
       );

  BoardEngineSession createSession() => BoardEngineSession._(this);

  final EngineWorkerSlot _slot;
  final Set<BoardEngineSession> _clients = {};
  var _queue = EngineSerialQueue();
  final Set<BoardEngineSession> _searchClients = {};
  final Map<BoardEngineSession, void Function(DiscoveryResult)> _progress = {};
  Object? _discoveryKey;
  Future<DiscoveryResult?>? _discovery;
  int _discoveryRequest = -1;
  DiscoveryResult? _latestProgress;
  int _request = 0;
  int _lifetime = 0;
  bool _suspended = false;

  int get workerCount => _slot.hasWorker ? 1 : 0;

  Future<T> _enqueue<T>(Future<T> Function() action) => _queue.run(action);

  Future<EvalWorker?> _ensure() => _slot.ensure(
    threads: EngineSettings.instance.cores,
    hashMb: EngineSettings.instance.hashMb,
  );

  /// Prepare the real configuration before the first toggle, without searching.
  Future<void> _prepare(BoardEngineSession client) {
    _clients.add(client);
    if (_suspended) return Future.value();
    return _ensure().then((_) {});
  }

  void _detach(BoardEngineSession client) {
    _clients.remove(client);
    _pause(client);
    // A route replacement can mount its new board in this same frame.
    scheduleMicrotask(() {
      if (_clients.isEmpty) _release();
    });
  }

  /// Returns null when superseded, paused or suspended. All engine work is
  /// serialized, including the final bestmove acknowledgement after a stop.
  Future<T?> _run<T>(
    BoardEngineSession owner,
    Future<T> Function(EvalWorker) search,
  ) {
    if (!_clients.contains(owner)) return Future.value();
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
        // Retry one retired process. The worker owns drain/CPU admission for
        // every search, so neither UI nor pool callers can skip that contract.
        for (var attempt = 0; ; attempt++) {
          final worker = await _ensure();
          if (!current()) return null;
          if (worker == null) throw StateError('Engine unavailable');
          try {
            final result = await search(worker);
            return current() ? result : null;
          } catch (_) {
            if (!current()) return null;
            if (!worker.isDead || attempt != 0) rethrow;
            _slot.release();
          }
        }
      } catch (_) {
        if (!current()) return null;
        rethrow;
      }
    });
  }

  /// Multiple views of the same board share both the search and live PVs.
  Future<DiscoveryResult?> _discover(
    BoardEngineSession owner, {
    required String fen,
    required int depth,
    required int multiPv,
    required bool whiteToMove,
    void Function(DiscoveryResult)? onProgress,
  }) {
    if (!_clients.contains(owner) || _suspended) return Future.value();
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
      _discovery = _run(
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
      final pending = _discovery!;
      // A failed search must not become a cached failure for this position.
      unawaited(
        pending.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {
            if (identical(_discovery, pending)) _discovery = null;
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

  void _pause(BoardEngineSession owner) {
    _progress.remove(owner);
    if (!_searchClients.remove(owner) || _searchClients.isNotEmpty) return;
    _request++;
    _slot.stop();
  }

  void _release() {
    _lifetime++;
    _request++;
    _searchClients.clear();
    _progress.clear();
    _discovery = null;
    _latestProgress = null;
    _slot.release();
  }

  /// Stop all board searches while retaining the configured idle process.
  void pauseAll() {
    _request++;
    _searchClients.clear();
    _progress.clear();
    _discovery = null;
    _latestProgress = null;
    _slot.stop();
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
    _queue = EngineSerialQueue();
  }
}

/// A pane's attachment and search ownership are the same typed handle.
/// Detach is reversible (hidden tabs); dispose is terminal (widget teardown).
class BoardEngineSession {
  BoardEngineSession._(this._engine);
  final BoardEngine _engine;
  bool _disposed = false;

  Future<void> prepare() {
    if (_disposed) return Future.error(StateError('Board session disposed'));
    return _engine._prepare(this);
  }

  Future<DiscoveryResult?> discover({
    required String fen,
    required int depth,
    required int multiPv,
    required bool whiteToMove,
    void Function(DiscoveryResult)? onProgress,
  }) {
    if (_disposed) return Future.error(StateError('Board session disposed'));
    return _engine._discover(
      this,
      fen: fen,
      depth: depth,
      multiPv: multiPv,
      whiteToMove: whiteToMove,
      onProgress: onProgress,
    );
  }

  Future<EvalResult?> evaluate(String fen, int depth) {
    if (_disposed) return Future.error(StateError('Board session disposed'));
    return _engine._run(this, (worker) => worker.evaluateFen(fen, depth));
  }

  void pause() => _engine._pause(this);
  void detach() => _engine._detach(this);
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    detach();
  }
}
