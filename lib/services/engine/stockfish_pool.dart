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
import 'engine_interrupt.dart';
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

  /// How many workers may run at once: the count the current consumer asked
  /// [ensureWorkers] for, never more than exist.
  ///
  /// This is not always [workerCount].  The pool only ever *grows* — workers
  /// left over from interactive analysis are reconfigured rather than killed —
  /// so a build that provisioned four lanes under a four-thread budget can
  /// find eight workers sitting there.  Running all eight would spend double
  /// the budget in threads and in hash, which is exactly what the lane split
  /// exists to avoid.
  int get concurrencyLimit => _targetCount > 0 && _targetCount < _workers.length
      ? _targetCount
      : _workers.length;

  /// UCI Threads applied when spawning or reconfiguring workers.
  int _threadsPerWorker = 1;
  int get threadsPerWorker => _threadsPerWorker;

  /// Last [ensureWorkers] target. Crash recovery respawns up to this count
  /// and does not spawn real engines for workers injected in tests.
  int _targetCount = 0;

  // ── Worker lifecycle ────────────────────────────────────────────────────

  /// Spawn workers up to [count].  Idempotent — only adds if fewer exist.
  ///
  /// [threadsPerWorker] sets Stockfish UCI Threads on each worker (MultiPV
  /// searches benefit strongly from >1 thread).  Existing workers are
  /// reconfigured when [threadsPerWorker] differs from the current value.
  Future<void> ensureWorkers([int? count, int? threadsPerWorker]) async {
    if (!StockfishConnectionFactory.isAvailable) return;

    if (threadsPerWorker != null && threadsPerWorker > 0) {
      _threadsPerWorker = threadsPerWorker;
    }

    final target = count ?? EngineSettings.instance.workers;
    _targetCount = target;
    while (_workers.length < target) {
      final w = await _spawnOne(_workers.length);
      if (w == null) break;
      _watchWorker(w);
      _workers.add(w);
      _free.add(w);
    }

    if (_workers.isNotEmpty &&
        _threadsPerWorker > 1 &&
        threadsPerWorker != null) {
      await reconfigureAllWorkers(_threadsPerWorker);
    }

    if (kDebugMode && _workers.isNotEmpty) {
      log.i(
        '[Pool] ${_workers.length} workers ready '
        '($kPoolHashPerWorkerMb MB hash, '
        '$_threadsPerWorker thread(s) each)',
      );
    }
  }

  /// Set UCI Threads on every live worker (e.g. before a tree build).
  Future<void> reconfigureAllWorkers(int threads) async {
    if (threads < 1) threads = 1;
    _threadsPerWorker = threads;
    await Future.wait([for (final w in _workers) w.setThreads(threads)]);
  }

  /// Prepare the pool for tree building with [threadBudget] engine threads
  /// in total.
  ///
  /// The budget is spread across *lanes* — independent workers that each
  /// expand a different frontier node — rather than handed to one worker as
  /// UCI Threads.  A fixed-depth search scales sub-linearly with threads
  /// (lazy SMP), while N single-thread workers on N different positions
  /// scale nearly linearly, so for the same CPU the build gets several times
  /// the throughput.  How many lanes: [EngineSettings.workers], capped by the
  /// budget so a 4-thread budget never spawns 8 workers; any threads left
  /// over after that split go to each worker (a 12-thread budget on a
  /// 4-worker setting gives 4 workers × 3 threads).
  ///
  /// Idempotent and safe to call over an existing pool: extra workers left
  /// by interactive analysis are reconfigured, not killed.
  Future<void> prepareForTreeBuild(int threadBudget) async {
    final lanes = laneCountFor(threadBudget);
    final perWorker = threadsPerLane(threadBudget, lanes);
    await ensureWorkers(lanes, perWorker);
    await reconfigureAllWorkers(perWorker);
  }

  /// Lanes a build should run for [threadBudget] threads: the configured
  /// worker count, clamped to the budget and to at least one.
  static int laneCountFor(int threadBudget, {int? workers}) {
    final budget = threadBudget < 1 ? 1 : threadBudget;
    final want = workers ?? EngineSettings.instance.workers;
    return want.clamp(1, budget);
  }

  /// UCI Threads per worker so [lanes] workers together use about
  /// [threadBudget] threads; never below one.
  static int threadsPerLane(int threadBudget, int lanes) {
    if (lanes < 1) return threadBudget < 1 ? 1 : threadBudget;
    final per = threadBudget ~/ lanes;
    return per < 1 ? 1 : per;
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
  Future<EvalWorker> acquire({Duration timeout = const Duration(seconds: 60)}) {
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
    return c.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(c);
        throw TimeoutException('Timed out waiting for a free worker', timeout);
      },
    );
  }

  /// Return a worker to the free set (or hand it to the next waiter).
  void release(EvalWorker worker) {
    _busy.remove(worker);
    if (worker.isDead || !_workers.contains(worker)) return;
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

  /// Evaluate multiple FENs, up to [workerCount] at a time, results in
  /// input order.
  ///
  /// Runs on [forEachParallel]: one worker acquisition per lane, held for
  /// the whole batch.  The previous `Future.wait(fens.map(evaluateFen))`
  /// parked every FEN as a waiter on [acquire] at once, and [acquire]'s
  /// 60 s timeout is counted from that moment — so on a one-worker pool any
  /// batch longer than ~15 depth-20 evals threw `TimeoutException` for its
  /// tail, which the verifier then reported as a failed pass.
  ///
  /// Throws [StateError] if a worker died mid-batch and left a slot empty.
  Future<List<EvalResult>> evaluateMany(List<String> fens, int depth) async {
    if (fens.isEmpty) return const [];
    final results = List<EvalResult?>.filled(fens.length, null);
    await forEachParallel(
      [for (var i = 0; i < fens.length; i++) i],
      (worker, i) async =>
          results[i] = await worker.evaluateFen(fens[i], depth),
    );
    return [
      for (final r in results)
        r ?? (throw StateError('Evaluation batch was interrupted')),
    ];
  }

  /// Process [items] in parallel across all workers using dynamic
  /// work-stealing: each worker pulls the next item the moment it finishes
  /// its previous one, so a single slow item never leaves other workers idle
  /// (unlike static round-robin partitioning of the work up front).
  ///
  /// Runs up to [concurrencyLimit] tasks concurrently.  [task] is handed an
  /// acquired worker — held for the whole call and released automatically —
  /// plus one item.  Pass [stopWhen] to abort remaining items *and* UCI-stop
  /// the in-flight search on that worker instead of waiting for depth.
  Future<void> forEachParallel<T>(
    List<T> items,
    Future<void> Function(EvalWorker worker, T item) task, {
    bool Function()? stopWhen,
  }) async {
    if (items.isEmpty) return;
    final concurrency = concurrencyLimit.clamp(1, items.length);
    var nextIndex = 0;

    Future<void> loop() async {
      final EvalWorker worker;
      try {
        worker = await acquire();
      } catch (e) {
        if (isEngineInterrupt(e)) return;
        rethrow;
      }
      try {
        while (true) {
          if (stopWhen != null && stopWhen()) {
            worker.stop();
            return;
          }
          final idx = nextIndex++;
          if (idx >= items.length) return;
          final future = task(worker, items[idx]);
          if (stopWhen == null) {
            await future;
          } else {
            await _awaitUntilStopped(worker, future, stopWhen);
          }
        }
      } catch (e) {
        if (isEngineInterrupt(e)) return;
        rethrow;
      } finally {
        release(worker);
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) loop()]);
  }

  Future<void> _awaitUntilStopped(
    EvalWorker worker,
    Future<void> future,
    bool Function() stopWhen,
  ) async {
    final poller = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (stopWhen()) worker.stop();
    });
    try {
      await future;
    } finally {
      poller.cancel();
    }
  }

  /// Run MultiPV discovery.  Acquires a worker for the duration.
  ///
  /// [searchMoves] restricts the search to those root moves; see
  /// [EvalWorker.runDiscovery].
  Future<DiscoveryResult> discoverMoves({
    required String fen,
    required int depth,
    required int multiPv,
    required bool isWhiteToMove,
    List<String>? searchMoves,
    void Function(DiscoveryResult)? onProgress,
  }) async {
    final w = await acquire();
    try {
      return await w.runDiscovery(
        fen,
        depth,
        multiPv,
        isWhiteToMove,
        searchMoves: searchMoves,
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

  void _watchWorker(EvalWorker worker) {
    worker.onDied = () {
      unawaited(_retireAndReplace(worker));
    };
  }

  Future<void> _retireAndReplace(EvalWorker dead) async {
    if (!_workers.contains(dead)) return;
    _workers.remove(dead);
    _busy.remove(dead);
    _free.remove(dead);
    try {
      dead.dispose();
    } catch (_) {
      /* already gone */
    }
    if (kDebugMode) {
      log.e('[Pool] Worker died; respawning');
    }
    if (_workers.length >= _targetCount) return;
    final replacement = await _spawnOne(_workers.length);
    if (replacement == null) return;
    _watchWorker(replacement);
    _workers.add(replacement);
    if (_waiters.isNotEmpty) {
      final next = _waiters.removeAt(0);
      _busy.add(replacement);
      if (!next.isCompleted) next.complete(replacement);
    } else {
      _free.add(replacement);
    }
  }

  /// Set the provisioned worker count without spawning anything, so a test
  /// can reach the state a build leaves behind: more workers alive than the
  /// current consumer asked for.
  @visibleForTesting
  void setTargetCountForTest(int count) => _targetCount = count;

  /// Inject a worker that was not spawned by [ensureWorkers] (unit tests).
  @visibleForTesting
  void addWorkerForTest(EvalWorker worker) {
    _watchWorker(worker);
    _workers.add(worker);
    _free.add(worker);
  }

  void _disposeAllWorkers() {
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
    _free.clear();
    _busy.clear();
    _targetCount = 0;
  }
}
