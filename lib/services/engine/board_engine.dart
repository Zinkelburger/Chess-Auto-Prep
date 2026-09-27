import 'dart:async';

import '../../models/analysis/discovery_result.dart';
import '../../features/settings/models/engine_configuration.dart';
import 'engine_connection.dart';
import 'engine_search_budget.dart';
import 'engine_serial_queue.dart';
import 'engine_worker_slot.dart';
import 'eval_worker.dart';

/// One process for interactive boards. Pausing retains its configured threads,
/// hash and network; only leaving all boards or suspending releases the process.
/// The latest search owns the worker. An old pane cannot stop a newer pane.
class BoardEngine {
  BoardEngine({
    Future<EngineConnection?> Function()? createConnection,
    required EngineSearchBudget budget,
    required EngineConfiguration Function() settings,
    Duration protocolTimeout = const Duration(seconds: 10),
  }) : _settings = settings,
       _slot = EngineWorkerSlot(
         createConnection: createConnection,
         budget: budget,
         protocolTimeout: protocolTimeout,
       );

  BoardEngineSession createSession() {
    if (_disposed) throw StateError("Board engine disposed");
    return BoardEngineSession._(this);
  }

  final EngineWorkerSlot _slot;
  final EngineConfiguration Function() _settings;
  bool _disposed = false;
  EngineConfiguration? _effectiveSettings;
  EngineConfiguration get effectiveSettings =>
      _effectiveSettings ?? _settings();

  /// Sessions currently attached (prepared and not yet detached).
  final Set<BoardEngineSession> _clients = {};
  var _queue = EngineSerialQueue();

  /// Sessions sharing the current search and its live progress.
  final Set<BoardEngineSession> _searchClients = {};
  final Map<BoardEngineSession, void Function(DiscoveryResult)> _progress = {};
  _DiscoveryKey? _discoveryKey;
  Future<DiscoveryResult?>? _discovery;
  int _discoveryRequest = -1;
  DiscoveryResult? _latestProgress;

  /// Bumped whenever a newer search, pause or release supersedes the current
  /// one; every queued step re-checks it before touching the worker.
  int _request = 0;

  /// Bumped on release so a queued [resume] does not revive a newer lifetime.
  int _lifetime = 0;
  bool _suspended = false;

  int get workerCount => _slot.hasWorker ? 1 : 0;

  Future<T> _enqueue<T>(Future<T> Function() action) => _queue.run(action);

  Future<EvalWorker?> _ensure([EngineConfiguration? captured]) async {
    final config = captured ?? _settings();
    final worker = await _slot.ensure(
      threads: config.cores,
      hashMb: config.hashMb,
    );
    if (worker != null) _effectiveSettings = config;
    return worker;
  }

  /// Prepare the real configuration before the first toggle, without searching.
  Future<void> _prepare(BoardEngineSession client) async {
    if (_disposed) throw StateError("Board engine disposed");
    _clients.add(client);
    if (_suspended) return;
    await _ensure();
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
    Future<T> Function(EvalWorker) search, {
    EngineConfiguration? configuration,
  }) {
    if (!_clients.contains(owner)) return Future.value();
    final captured = configuration ?? owner._configuration ?? _settings();
    final request = ++_request;
    _searchClients
      ..clear()
      ..add(owner);
    _progress.clear();
    _slot.stop();
    return _enqueue(() async {
      bool current() => request == _request && !_suspended && !_disposed;
      if (!current()) return null;
      try {
        // Retry one retired process. The worker owns drain/CPU admission for
        // every search, so neither UI nor pool callers can skip that contract.
        for (var attempt = 0; ; attempt++) {
          final worker = await _ensure(captured);
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
    final captured = owner._configuration = _settings();
    final key = (
      fen: fen,
      depth: depth,
      multiPv: multiPv,
      whiteToMove: whiteToMove,
      cores: captured.cores,
      hashMb: captured.hashMb,
    );
    final discovery =
        _discovery == null ||
            _discoveryKey != key ||
            _discoveryRequest != _request
        ? _startDiscovery(owner, key, captured)
        : _discovery!;
    _searchClients.add(owner);
    if (onProgress != null) {
      _progress[owner] = onProgress;
      final latest = _latestProgress;
      if (latest != null) onProgress(latest);
    }
    final request = _request;
    return discovery.then(
      (result) =>
          request == _request && _searchClients.contains(owner) ? result : null,
    );
  }

  Future<DiscoveryResult?> _startDiscovery(
    BoardEngineSession owner,
    _DiscoveryKey key,
    EngineConfiguration captured,
  ) {
    _latestProgress = null;
    final pending = _discovery = _run(
      owner,
      (worker) => worker.runDiscovery(
        key.fen,
        key.depth,
        key.multiPv,
        key.whiteToMove,
        onProgress: (result) {
          _latestProgress = result;
          for (final entry in Map.of(_progress).entries) {
            if (_searchClients.contains(entry.key)) entry.value(result);
          }
        },
      ),
      configuration: captured,
    );
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
    return pending;
  }

  void _pause(BoardEngineSession owner) {
    _progress.remove(owner);
    if (!_searchClients.remove(owner) || _searchClients.isNotEmpty) return;
    _request++;
    _slot.stop();
  }

  /// Supersede every search and forget the shared discovery.
  void _abandonSearches() {
    _request++;
    _searchClients.clear();
    _progress.clear();
    _discovery = null;
    _latestProgress = null;
  }

  void _release() {
    _lifetime++;
    _abandonSearches();
    _slot.release();
  }

  /// Stop all board searches while retaining the configured idle process.
  void pauseAll() {
    _abandonSearches();
    _slot.stop();
  }

  void suspend() {
    _suspended = true;
    _release();
  }

  Future<void> resume() {
    if (_disposed) return Future.value();
    _suspended = false;
    final lifetime = _lifetime;
    return _enqueue(() async {
      if (lifetime == _lifetime && !_suspended && _clients.isNotEmpty) {
        await _ensure();
      }
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _suspended = true;
    _clients.clear();
    _release();
    _queue = EngineSerialQueue();
  }
}

/// What makes two board discoveries the same search.
typedef _DiscoveryKey = ({
  String fen,
  int depth,
  int multiPv,
  bool whiteToMove,
  int cores,
  int hashMb,
});

/// A pane's attachment and search ownership are the same typed handle.
/// Detach is reversible (hidden tabs); dispose is terminal (widget teardown).
class BoardEngineSession {
  BoardEngineSession._(this._engine);
  final BoardEngine _engine;
  EngineConfiguration? _configuration;
  bool _disposed = false;

  Future<void> prepare() {
    if (_disposed) return Future.error(_disposedError());
    return _engine._prepare(this);
  }

  Future<DiscoveryResult?> discover({
    required String fen,
    required int depth,
    required int multiPv,
    required bool whiteToMove,
    void Function(DiscoveryResult)? onProgress,
  }) {
    if (_disposed) return Future.error(_disposedError());
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
    if (_disposed) return Future.error(_disposedError());
    return _engine._run(this, (worker) => worker.evaluateFen(fen, depth));
  }

  void pause() => _engine._pause(this);
  void detach() => _engine._detach(this);
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    detach();
  }

  static StateError _disposedError() => StateError('Board session disposed');
}
