import 'dart:async';

import 'engine_connection.dart';
import 'eval_worker.dart';
import 'engine_search_budget.dart';
import 'stockfish_connection_factory.dart';

/// Owns one lazily started worker, including its unfinished initialization.
/// Releasing the slot invalidates pending creation before it can publish a
/// worker. Overlapping callers share the same initialization.
class EngineWorkerSlot {
  EngineWorkerSlot({
    Future<EngineConnection?> Function()? createConnection,
    this.budget,
    this.protocolTimeout = const Duration(seconds: 10),
  }) : _createConnection =
           createConnection ?? StockfishConnectionFactory.create;
  final EngineSearchBudget? budget;
  final Duration protocolTimeout;

  final Future<EngineConnection?> Function() _createConnection;
  EvalWorker? _worker;
  Future<EvalWorker?>? _pending;
  int _generation = 0;
  int? _threads;
  int? _hashMb;

  bool get hasWorker => _worker != null && !_worker!.isDead;

  void stop() => _worker?.stop();

  Future<EvalWorker?> ensure({required int threads, int hashMb = 128}) {
    if (_worker?.isDead ?? false) release();
    final changed = _threads != threads || _hashMb != hashMb;
    if (_pending != null) {
      if (!changed) return _pending!;
      return _pending!.then((_) => ensure(threads: threads, hashMb: hashMb));
    }
    _threads = threads;
    _hashMb = hashMb;
    if (_worker != null) {
      if (!changed) return Future.value(_worker);
      final worker = _worker!;
      final generation = _generation;
      return _pending =
          (() async {
            await worker.setThreads(threads);
            await worker.setHash(hashMb);
            return generation == _generation && !worker.isDead ? worker : null;
          })().whenComplete(() {
            if (generation == _generation) _pending = null;
          });
    }
    final generation = _generation;
    return _pending = _start(generation, threads, hashMb).whenComplete(() {
      if (generation == _generation) _pending = null;
    });
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
          .timeout(const Duration(seconds: 15));
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
