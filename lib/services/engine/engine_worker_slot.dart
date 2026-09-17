import 'dart:async';

import 'engine_connection.dart';
import 'engine_search_budget.dart';
import 'eval_worker.dart';
import 'stockfish_connection_factory.dart';

/// Owns one lazily started worker, including its unfinished initialization.
/// Releasing the slot invalidates pending creation before it can publish a
/// worker. Overlapping callers share the same initialization.
class EngineWorkerSlot {
  EngineWorkerSlot({
    Future<EngineConnection?> Function()? createConnection,
    required this.budget,
    this.protocolTimeout = const Duration(seconds: 10),
  }) : _createConnection =
           createConnection ?? StockfishConnectionFactory.create;

  static const _startupTimeout = Duration(seconds: 15);

  final EngineSearchBudget budget;
  final Duration protocolTimeout;

  final Future<EngineConnection?> Function() _createConnection;
  EvalWorker? _worker;
  Future<EvalWorker?>? _pending;

  /// Bumped by [release]; a start or reconfiguration from an older generation
  /// discards its result instead of publishing a stale worker.
  int _generation = 0;
  int? _threads;
  int? _hashMb;

  bool get hasWorker {
    final worker = _worker;
    return worker != null && !worker.isDead;
  }

  void stop() => _worker?.stop();

  /// The live worker configured with [threads]/[hashMb], starting or
  /// reconfiguring one as needed. Null when the slot was released meanwhile
  /// or no engine is available.
  Future<EvalWorker?> ensure({required int threads, int hashMb = 128}) {
    if (_worker?.isDead ?? false) release();
    final changed = _threads != threads || _hashMb != hashMb;
    final pending = _pending;
    if (pending != null) {
      if (!changed) return pending;
      return pending.then((_) => ensure(threads: threads, hashMb: hashMb));
    }
    _threads = threads;
    _hashMb = hashMb;
    final worker = _worker;
    if (worker != null && !changed) return Future.value(worker);
    final generation = _generation;
    final started = worker == null
        ? _start(generation, threads, hashMb)
        : _reconfigure(worker, generation, threads, hashMb);
    return _pending = started.whenComplete(() {
      if (generation == _generation) _pending = null;
    });
  }

  Future<EvalWorker?> _reconfigure(
    EvalWorker worker,
    int generation,
    int threads,
    int hashMb,
  ) async {
    await worker.setThreads(threads);
    await worker.setHash(hashMb);
    return generation == _generation && !worker.isDead ? worker : null;
  }

  Future<EvalWorker?> _start(int generation, int threads, int hashMb) async {
    EvalWorker? worker;
    try {
      final connection = await _createConnection();
      if (connection == null) return null;
      if (generation != _generation) {
        connection.dispose();
        return null;
      }
      worker = EvalWorker(
        connection,
        budget: budget,
        protocolTimeout: protocolTimeout,
      );
      _worker = worker;
      await worker
          .init(hashMb: hashMb, threads: threads)
          .timeout(_startupTimeout);
      if (generation != _generation || worker.isDead) {
        worker.dispose();
        return null;
      }
      return worker;
    } catch (_) {
      worker?.dispose();
      if (generation == _generation) _worker = null;
      rethrow;
    }
  }

  void release() {
    _generation++;
    _worker?.dispose();
    _worker = null;
    _pending = null;
    _threads = null;
    _hashMb = null;
  }
}
