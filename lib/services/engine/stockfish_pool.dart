/// Pure Stockfish worker pool — spawns workers, provides acquire/release.
///
/// No analysis orchestration, no UI concerns, no dynamic RAM budgeting.
/// Workers use a fixed 64 MB hash and a single thread each.
///
/// Used by [AnalysisService] for interactive analysis and by
/// [RepertoireGenerationService] for generation-mode evaluation.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/analysis/discovery_result.dart';
import '../../models/engine_settings.dart';
import 'eval_worker.dart';
import 'stockfish_connection_factory.dart';

export 'eval_worker.dart' show EvalResult;
export '../../models/analysis/discovery_result.dart';

/// Fixed hash per worker in MB.  128 MB gives comfortable headroom up to ~depth 25.
const int kPoolHashPerWorkerMb = 128;

class StockfishPool {
  // ── Singleton ───────────────────────────────────────────────────────────
  static final StockfishPool _instance = StockfishPool._();
  factory StockfishPool() => _instance;
  StockfishPool._();

  // ── State ───────────────────────────────────────────────────────────────
  final List<EvalWorker> _workers = [];
  final Set<EvalWorker> _free = {};
  final Set<EvalWorker> _busy = {};
  final List<Completer<EvalWorker>> _waiters = [];

  int get workerCount => _workers.length;

  // ── Worker lifecycle ────────────────────────────────────────────────────

  /// Spawn workers up to [count].  Idempotent — only adds if fewer exist.
  Future<void> ensureWorkers([int? count]) async {
    if (!StockfishConnectionFactory.isAvailable) return;

    final target = count ?? EngineSettings().workers;
    while (_workers.length < target) {
      final w = await _spawnOne(_workers.length);
      if (w == null) break;
      _workers.add(w);
      _free.add(w);
    }

    if (kDebugMode && _workers.isNotEmpty) {
      print('[Pool] ${_workers.length} workers ready '
          '(${kPoolHashPerWorkerMb} MB hash each)');
    }
  }

  Future<EvalWorker?> _spawnOne(int index) async {
    try {
      final engine = await StockfishConnectionFactory.create();
      if (engine == null) return null;
      final worker = EvalWorker(engine);
      await worker.init(hashMb: kPoolHashPerWorkerMb);
      return worker;
    } catch (e) {
      if (kDebugMode) print('[Pool] Worker #$index spawn failed: $e');
      return null;
    }
  }

  /// Warm up all workers with a quick depth-10 eval of the start position.
  Future<void> warmUp() async {
    await ensureWorkers();
    if (_workers.isEmpty) return;
    const startpos =
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    try {
      await Future.wait([
        for (final w in _workers) w.evaluateFen(startpos, 10),
      ]);
    } catch (_) {}
  }

  // ── Acquire / release ───────────────────────────────────────────────────

  /// Acquire exclusive use of a worker.  Queues if all are busy.
  Future<EvalWorker> acquire() {
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
    return c.future;
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
        fen, depth, multiPv, isWhiteToMove,
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

  /// Dispose everything.  Called when leaving the repertoire screen.
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
