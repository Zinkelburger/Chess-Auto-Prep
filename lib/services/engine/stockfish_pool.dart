/// Pure Stockfish worker pool — spawns workers, provides acquire/release.
///
/// No analysis orchestration, no UI concerns, no dynamic RAM budgeting.
/// Workers use a fixed [kPoolHashPerWorkerMb] MB hash and a single thread
/// each.
///
/// Used by [AnalysisService] for interactive analysis and by
/// [TreeBuildService] for generation-mode evaluation.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/analysis/discovery_result.dart';
import '../../models/engine_settings.dart';
import 'eval_worker.dart';
import 'stockfish_connection_factory.dart';
import 'package:chess_auto_prep/utils/log.dart';

export 'eval_worker.dart' show EvalResult, EvalWorker;
export '../../models/analysis/discovery_result.dart';

/// Fixed hash per worker in MB.  128 MB gives comfortable headroom up to ~depth 25.
const int kPoolHashPerWorkerMb = 128;

class StockfishPool {
  // ── Singleton ───────────────────────────────────────────────────────────
  /// Application-wide shared instance.
  static final StockfishPool instance = StockfishPool._();

  /// Create an independent instance (unit tests only).
  @visibleForTesting
  StockfishPool.fresh() : this._();

  StockfishPool._();

  // ── State ───────────────────────────────────────────────────────────────
  final List<EvalWorker> _workers = [];
  final Set<EvalWorker> _free = {};
  final Set<EvalWorker> _busy = {};
  final List<Completer<EvalWorker>> _waiters = [];

  int get workerCount => _workers.length;

  /// UCI Threads applied when spawning or reconfiguring workers.
  int _threadsPerWorker = 1;
  int get threadsPerWorker => _threadsPerWorker;

  // ── Worker lifecycle ────────────────────────────────────────────────────

  /// Spawn workers up to [count].  Idempotent — only adds if fewer exist.
  ///
  /// [threadsPerWorker] sets Stockfish UCI Threads on each worker (MultiPV
  /// searches benefit strongly from >1 thread).  Existing workers are
  /// reconfigured when [threadsPerWorker] differs from the current value.
  Future<void> ensureWorkers([
    int? count,
    int? threadsPerWorker,
  ]) async {
    if (!StockfishConnectionFactory.isAvailable) return;

    if (threadsPerWorker != null && threadsPerWorker > 0) {
      _threadsPerWorker = threadsPerWorker;
    }

    final target = count ?? EngineSettings.instance.workers;
    while (_workers.length < target) {
      final w = await _spawnOne(_workers.length);
      if (w == null) break;
      _workers.add(w);
      _free.add(w);
    }

    if (_workers.isNotEmpty &&
        _threadsPerWorker > 1 &&
        threadsPerWorker != null) {
      await reconfigureAllWorkers(_threadsPerWorker);
    }

    if (kDebugMode && _workers.isNotEmpty) {
      log.i('[Pool] ${_workers.length} workers ready '
          '($kPoolHashPerWorkerMb MB hash, '
          '$_threadsPerWorker thread(s) each)');
    }
  }

  /// Set UCI Threads on every live worker (e.g. before a tree build).
  Future<void> reconfigureAllWorkers(int threads) async {
    if (threads < 1) threads = 1;
    _threadsPerWorker = threads;
    await Future.wait([
      for (final w in _workers) w.setThreads(threads),
    ]);
  }

  /// Prepare the pool for tree building: ensure at least one worker and
  /// apply [threads] UCI Threads for faster MultiPV.
  Future<void> prepareForTreeBuild(int threads) async {
    await ensureWorkers(1, threads);
    await reconfigureAllWorkers(threads);
  }

  Future<EvalWorker?> _spawnOne(int index) async {
    try {
      final engine = await StockfishConnectionFactory.create();
      if (engine == null) return null;
      final worker = EvalWorker(engine);
      await worker.init(
        hashMb: kPoolHashPerWorkerMb,
        threads: _threadsPerWorker,
      );
      return worker;
    } catch (e) {
      if (kDebugMode) log.e('[Pool] Worker #$index spawn failed: $e');
      return null;
    }
  }

  /// Warm up all workers with a quick depth-10 eval of the start position.
  Future<void> warmUp() async {
    await ensureWorkers();
    if (_workers.isEmpty) return;
    const startpos = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    try {
      await Future.wait([
        for (final w in _workers) w.evaluateFen(startpos, 10),
      ]);
    } catch (e) {
      debugPrint('[StockfishPool] Warmup eval failed: $e');
    }
  }

  // ── Acquire / release ───────────────────────────────────────────────────

  /// Acquire exclusive use of a worker.  Queues if all are busy.
  ///
  /// Times out after [timeout] (default 60 s) to prevent deadlocks when a
  /// worker hangs.
  Future<EvalWorker> acquire({
    Duration timeout = const Duration(seconds: 60),
  }) {
    if (_workers.isEmpty) {
      return Future.error(StateError('No workers available'));
    }
    if (_free.isNotEmpty) {
      final w = _free.first;
      _free.remove(w);
      _busy.add(w);
      return Future.value(w);
    }
    final c = Completer<EvalWorker>();
    _waiters.add(c);
    return c.future.timeout(timeout, onTimeout: () {
      _waiters.remove(c);
      throw TimeoutException('Timed out waiting for a free worker', timeout);
    });
  }

  /// Return a worker to the free set (or hand it to the next waiter).
  void release(EvalWorker worker) {
    _busy.remove(worker);
    if (!_workers.contains(worker)) return;
    if (_waiters.isNotEmpty) {
      final next = _waiters.removeAt(0);
      _busy.add(worker);
      if (!next.isCompleted) next.complete(worker);
    } else {
      _free.add(worker);
    }
  }

  // ── Convenience evaluation methods ──────────────────────────────────────

  /// Acquire a worker, evaluate [fen] at [depth], release.
  Future<EvalResult> evaluateFen(String fen, int depth) async {
    final w = await acquire();
    try {
      return await w.evaluateFen(fen, depth);
    } finally {
      release(w);
    }
  }

  /// Evaluate multiple FENs.  Each acquires its own worker, so up to
  /// [workerCount] evaluations run in parallel.
  Future<List<EvalResult>> evaluateMany(List<String> fens, int depth) async {
    if (fens.isEmpty) return const [];
    return Future.wait(fens.map((f) => evaluateFen(f, depth)));
  }

  /// Process [items] in parallel across all workers using dynamic
  /// work-stealing: each worker pulls the next item the moment it finishes
  /// its previous one, so a single slow item never leaves other workers idle
  /// (unlike static round-robin partitioning of the work up front).
  ///
  /// Runs up to [workerCount] tasks concurrently.  [task] is handed an
  /// acquired worker — held for the whole call and released automatically —
  /// plus one item.  Pass [stopWhen] to abort *remaining* items early (e.g.
  /// on cancellation); items already in flight still run to completion.
  Future<void> forEachParallel<T>(
    List<T> items,
    Future<void> Function(EvalWorker worker, T item) task, {
    bool Function()? stopWhen,
  }) async {
    if (items.isEmpty) return;
    final concurrency = workerCount.clamp(1, items.length);
    var nextIndex = 0;

    Future<void> loop() async {
      final worker = await acquire();
      try {
        while (stopWhen == null || !stopWhen()) {
          final idx = nextIndex++;
          if (idx >= items.length) return;
          await task(worker, items[idx]);
        }
      } finally {
        release(worker);
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) loop()]);
  }

  /// Run MultiPV discovery.  Acquires a worker for the duration.
  Future<DiscoveryResult> discoverMoves({
    required String fen,
    required int depth,
    required int multiPv,
    required bool isWhiteToMove,
    void Function(DiscoveryResult)? onProgress,
  }) async {
    final w = await acquire();
    try {
      return await w.runDiscovery(
        fen,
        depth,
        multiPv,
        isWhiteToMove,
        onProgress: onProgress,
      );
    } finally {
      release(w);
    }
  }

  // ── Stop / suspend / dispose ────────────────────────────────────────────

  /// Send UCI `stop` to every worker.  Instant CPU release.
  void stopAll() {
    for (final w in _workers) {
      w.stop();
    }
    // Reject any pending acquires.
    for (final c in _waiters) {
      if (!c.isCompleted) c.completeError(StateError('Pool stopped'));
    }
    _waiters.clear();
  }

  /// Kill all Stockfish processes to free RAM (e.g. DB-only generation).
  void suspend() {
    stopAll();
    _disposeAllWorkers();
  }

  /// Dispose everything.
  void dispose() {
    stopAll();
    _disposeAllWorkers();
  }

  void _disposeAllWorkers() {
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
    _free.clear();
    _busy.clear();
  }
}
