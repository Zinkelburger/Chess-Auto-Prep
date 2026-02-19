/// Parallel move analysis using a pool of persistent Stockfish workers.
///
/// Workers are spawned once (on repertoire load) and persist for the session.
/// The pool handles two phases:
///   1. **Discovery** — MultiPV analysis on the root position to find top moves.
///   2. **Evaluation** — Per-move deep eval + ease using parallel workers.
library;

import 'dart:async';
import 'dart:math' as math;
import 'package:chess/chess.dart' as chess;
import 'package:flutter/foundation.dart';

import 'engine/stockfish_connection_factory.dart';
import 'maia_factory.dart';
import 'probability_service.dart';
import 'engine/eval_worker.dart';
import 'pool_resource_budget.dart';
import '../models/engine_settings.dart';
import '../models/analysis/discovery_result.dart';
import '../models/analysis/move_analysis_result.dart';
import '../utils/system_info.dart';
import '../utils/ease_utils.dart';
import '../utils/chess_utils.dart' show playUciMove;

// Re-export the model types so existing `import 'move_analysis_pool.dart'`
// statements continue to resolve DiscoveryResult, MoveAnalysisResult, etc.
export '../models/analysis/discovery_result.dart';
export '../models/analysis/move_analysis_result.dart';
export '../utils/ease_utils.dart'
    show scoreToQ, kEaseAlpha, kEaseBeta, kEaseDisplayScale;

// ── Worker Pool ──────────────────────────────────────────────────────────

class MoveAnalysisPool {
  static final MoveAnalysisPool _instance = MoveAnalysisPool._();
  factory MoveAnalysisPool() => _instance;
  MoveAnalysisPool._();

  final List<EvalWorker> _workers = [];
  int _generation = 0;

  // ── Evaluation state ──
  String? _currentBaseFen;
  List<String> _moveQueue = [];
  int _nextMoveIndex = 0;
  int _evalDepth = 20;
  int _easeDepth = 12;
  double _maxLoadPercent = 80.0;

  /// Target worker count for the current generation (scale-up goal).
  int _targetMaxWorkers = 1;

  final Map<int, String> _workerCurrentMoves = {};
  final ProbabilityService _probabilityService = ProbabilityService();

  // ── Public notifiers ──
  final ValueNotifier<DiscoveryResult> discoveryResult =
      ValueNotifier(const DiscoveryResult());
  final ValueNotifier<Map<String, MoveAnalysisResult>> results =
      ValueNotifier({});
  final ValueNotifier<PoolStatus> poolStatus =
      ValueNotifier(const PoolStatus());

  // ── Worker lifecycle helpers ───────────────────────────────────────────

  void _trimWorkersTo(int count) {
    while (_workers.length > count) {
      _workers.removeLast().dispose();
    }
  }

  void _disposeAllWorkers() {
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
  }

  // ── Dynamic resource budgeting ──────────────────────────────────────
  //
  // RAM is the only hard constraint.  CPU utilisation is noisy / bursty
  // so we never gate worker count on it.  Instead we:
  //   1. Compute per-worker hash assuming ALL maxWorkers will run.
  //   2. Spawn as many as RAM headroom allows right now.
  //   3. A background scale-up loop tries to add 1 more worker every
  //      few seconds until we reach maxWorkers or headroom runs out.
  //   4. On each new evaluation, recompute hash from current headroom
  //      and redistribute to all workers (Stockfish accepts lower Hash).
  //
  // All pure math lives in [PoolResourceBudget] so it can be tested
  // independently with synthetic system snapshots.

  /// Interval between scale-up attempts.
  static const Duration _scaleUpInterval = Duration(seconds: 3);

  int _lastHashPerWorkerMb = 0;

  /// Build a [SystemSnapshot] + [PoolState] from live OS data and
  /// current pool state, then run [PoolResourceBudget.compute].
  ResourceBudget _computeBudget(double maxLoadPercent, int maxWorkers) {
    final settings = EngineSettings();
    final load = getSystemLoad();

    final system = load != null
        ? SystemSnapshot(
            totalRamMb: load.totalRamMb,
            freeRamMb: load.freeRamMb,
            logicalCores: load.logicalCores,
          )
        : SystemSnapshot(
            totalRamMb: EngineSettings.systemRamMb,
            freeRamMb: EngineSettings.systemRamMb,
            logicalCores: EngineSettings.systemCores,
          );

    final pool = PoolState(
      workerCount: _workers.length,
      hashPerWorkerMb: _lastHashPerWorkerMb,
    );

    return PoolResourceBudget.compute(
      system: system,
      maxLoadPercent: maxLoadPercent,
      maxWorkers: maxWorkers,
      hashCeilingMb: settings.hashPerWorker,
      pool: pool,
    );
  }

  /// Convenience: can RAM fit one more worker at current hash?
  bool _canFitOneMore() {
    final budget = _computeBudget(_maxLoadPercent, _targetMaxWorkers);
    return budget.workerCapacity > _workers.length;
  }

  void _applyHash(int hashMb) {
    if (hashMb == _lastHashPerWorkerMb) return;
    for (final w in _workers) {
      w.updateHash(hashMb);
    }
    _lastHashPerWorkerMb = hashMb;
  }

  /// Recompute hash from current RAM headroom and apply to all workers.
  void _rebalanceHash() {
    final budget = _computeBudget(_maxLoadPercent, _targetMaxWorkers);
    if (budget.hashPerWorkerMb != _lastHashPerWorkerMb &&
        _workers.isNotEmpty) {
      if (kDebugMode) {
        print('[Pool] Hash rebalance: $_lastHashPerWorkerMb → '
            '${budget.hashPerWorkerMb} MB/worker');
      }
      _applyHash(budget.hashPerWorkerMb);
    }
  }

  // ── Worker creation ──────────────────────────────────────────────────

  /// Lock to prevent concurrent spawn storms.
  /// If warmUp is mid-spawn and discovery calls _ensureWorkers, the second
  /// call waits for the first to finish rather than spawning a duplicate fleet.
  Completer<void>? _spawnLock;

  /// Spawn workers up to what RAM allows right now (targeting maxWorkers).
  ///
  /// Hash is pre-computed for [maxWorkers] so every worker gets the same
  /// share regardless of how many are alive.  The background scale-up
  /// loop ([_scaleUpLoop]) keeps trying to reach [maxWorkers].
  ///
  /// Workers are **never disposed** due to generation changes — they are
  /// expensive to create and persist for the session.  Only [cancel] /
  /// [dispose] should remove workers.
  Future<void> _ensureWorkers({
    required double maxLoadPercent,
    required int maxWorkers,
  }) async {
    // Serialize: wait for any in-flight spawn to finish first.
    if (_spawnLock != null) {
      await _spawnLock!.future;
      // Previous call already handled spawning; update targets and return.
      _targetMaxWorkers = maxWorkers;
      _maxLoadPercent = maxLoadPercent;
      return;
    }

    _spawnLock = Completer<void>();
    try {
      await _ensureWorkersLocked(
        maxLoadPercent: maxLoadPercent,
        maxWorkers: maxWorkers,
      );
    } finally {
      _spawnLock!.complete();
      _spawnLock = null;
    }
  }

  Future<void> _ensureWorkersLocked({
    required double maxLoadPercent,
    required int maxWorkers,
  }) async {
    if (!StockfishConnectionFactory.isAvailable) {
      _disposeAllWorkers();
      poolStatus.value = const PoolStatus(phase: 'idle');
      return;
    }

    _targetMaxWorkers = maxWorkers;
    _maxLoadPercent = maxLoadPercent;

    final budget = _computeBudget(maxLoadPercent, maxWorkers);
    final hash = budget.hashPerWorkerMb;
    final capacity = budget.workerCapacity;

    if (kDebugMode) {
      final load = getSystemLoad();
      if (load != null) {
        final pool = PoolState(
          workerCount: _workers.length,
          hashPerWorkerMb: _lastHashPerWorkerMb,
        );
        print('[Pool] System: '
            'CPU ${load.cpuPercent.toStringAsFixed(0)}% · '
            'RAM ${load.totalRamMb - load.freeRamMb}/${load.totalRamMb} MB used '
            '(${load.freeRamMb} MB free, '
            '${load.ramPercent.toStringAsFixed(0)}%) · '
            'headroom ${budget.effectiveHeadroomMb} MB effective '
            '(${pool.ownAllocationMb} MB own) '
            'at ${maxLoadPercent.round()}% ceiling');
        print('[Pool] Plan: $hash MB/worker × $maxWorkers target '
            '(have ${_workers.length}, RAM fits $capacity)');
      } else {
        print('[Pool] System load unavailable — '
            'spawning $maxWorkers workers');
      }
    }

    // Rebalance hash on existing workers (may have changed since last call).
    if (_workers.isNotEmpty && hash != _lastHashPerWorkerMb) {
      _applyHash(hash);
    }

    if (_workers.length > capacity) {
      _trimWorkersTo(capacity);
    }

    if (_workers.length >= capacity) {
      _lastHashPerWorkerMb = hash;
      return;
    }

    final needed = capacity - _workers.length;
    final startIndex = _workers.length;

    final spawnFutures = <Future<EvalWorker?>>[];
    for (int i = 0; i < needed; i++) {
      spawnFutures.add(_spawnOneWorker(startIndex + i, hash));
    }

    final spawned = await Future.wait(spawnFutures);

    // Always keep spawned workers — they're expensive to create.
    // Generation changes only cancel analysis, never worker lifecycle.
    for (final w in spawned) {
      if (w != null) {
        _workers.add(w);
      }
    }

    _lastHashPerWorkerMb = hash;

    if (kDebugMode && _workers.isNotEmpty) {
      _logAllocation(maxLoadPercent);
    }
  }

  Future<EvalWorker?> _spawnOneWorker(int index, int hashMb) async {
    try {
      final engine = await StockfishConnectionFactory.create();
      if (engine == null) return null;
      final worker = EvalWorker(engine);
      await worker.init(hashMb: hashMb);
      return worker;
    } catch (e) {
      if (kDebugMode) print('[Pool] Worker #$index spawn FAILED: $e');
      return null;
    }
  }

  void _logAllocation(double maxLoadPercent) {
    final totalHashMb = _workers.length * _lastHashPerWorkerMb;
    final totalOverheadMb = _workers.length * kProcessOverheadMb;
    final totalMb = totalHashMb + totalOverheadMb;
    final load = getSystemLoad();
    final ceilingMb = load != null
        ? (load.totalRamMb * maxLoadPercent / 100).round()
        : 0;
    final usedMb = load != null ? load.totalRamMb - load.freeRamMb : 0;
    print('[Pool] Allocation: ${_workers.length}/$_targetMaxWorkers workers × '
        '$_lastHashPerWorkerMb MB hash + '
        '$kProcessOverheadMb MB overhead = '
        '$totalMb MB total '
        '(${usedMb + totalMb}/$ceilingMb MB of '
        '${maxLoadPercent.round()}% ceiling)');
  }

  // ── Background scale-up loop ────────────────────────────────────────

  /// Periodically tries to spawn additional workers until [_targetMaxWorkers]
  /// is reached or RAM runs out.  Runs alongside worker eval loops.
  void _startScaleUpLoop(int generation) {
    if (_workers.length >= _targetMaxWorkers) return;

    Future.doWhile(() async {
      await Future.delayed(_scaleUpInterval);
      if (_generation != generation) return false;
      if (_workers.length >= _targetMaxWorkers) return false;

      // Check RAM before spawning
      if (!_canFitOneMore()) {
        if (kDebugMode) {
          print('[Pool] Scale-up: RAM full at ${_workers.length} workers '
              '(target $_targetMaxWorkers)');
        }
        return _generation == generation; // keep polling
      }

      final worker = await _spawnOneWorker(
          _workers.length, _lastHashPerWorkerMb);
      if (_generation != generation) {
        worker?.dispose();
        return false;
      }

      if (worker != null) {
        _workers.add(worker);
        if (kDebugMode) {
          print('[Pool] Scale-up: spawned worker #${_workers.length - 1} '
              '(${_workers.length}/$_targetMaxWorkers)');
        }
        _emitPoolStatus();
        // Start a worker loop for the new worker if we're evaluating
        if (_currentBaseFen != null) {
          _workerLoop(worker, _workers.length - 1, generation);
        }
      }

      return _generation == generation &&
          _workers.length < _targetMaxWorkers;
    });
  }

  // ── Warm-up ─────────────────────────────────────────────────────────

  Future<void> warmUp() async {
    final settings = EngineSettings();
    final maxWorkers = settings.cores;
    final maxLoadPercent = settings.maxSystemLoad.toDouble();

    _generation++;
    final myGen = _generation;

    await _ensureWorkers(
      maxLoadPercent: maxLoadPercent,
      maxWorkers: maxWorkers,
    );

    if (_generation != myGen || _workers.isEmpty) return;

    // Start scaling up in the background while we warm up worker #0.
    _startScaleUpLoop(myGen);

    const startpos =
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    try {
      await Future.wait([
        for (final w in _workers) w.evaluateFen(startpos, 10),
      ]);
    } catch (_) {}
  }

  // ── Discovery: MultiPV on root position ─────────────────────────────

  /// Run MultiPV discovery on [fen] using worker #0.
  /// Returns the final result; emits intermediate progress to [discoveryResult].
  Future<DiscoveryResult> runDiscovery({
    required String fen,
    required int depth,
    required int multiPv,
  }) async {
    _generation++;
    final myGen = _generation;

    // Cancel in-progress work
    for (final w in _workers) {
      w.stop();
    }
    _workerCurrentMoves.clear();
    _currentBaseFen = null;
    results.value = {};
    discoveryResult.value = const DiscoveryResult();

    final settings = EngineSettings();

    // Ensure workers exist (fixes warmUp race condition)
    await _ensureWorkers(
      maxLoadPercent: settings.maxSystemLoad.toDouble(),
      maxWorkers: settings.cores,
    );

    if (_generation != myGen || _workers.isEmpty) {
      return const DiscoveryResult();
    }

    // Scale up in background while discovery runs on worker #0.
    _startScaleUpLoop(myGen);

    final fenParts = fen.split(' ');
    final isWhiteToMove = fenParts.length >= 2 && fenParts[1] == 'w';

    poolStatus.value = PoolStatus(
      phase: 'discovering',
      activeWorkers: _workers.length,
      hashPerWorkerMb: _lastHashPerWorkerMb,
    );

    if (kDebugMode) {
      print('[Pool] Discovery START — MultiPV=$multiPv, depth=$depth, '
          'workers=${_workers.length}/$_targetMaxWorkers, '
          'hash=${_lastHashPerWorkerMb} MB/worker');
    }

    try {
      final result = await _workers[0].runDiscovery(
        fen, depth, multiPv, isWhiteToMove,
        onProgress: (intermediate) {
          if (_generation != myGen) return;
          discoveryResult.value = intermediate;
          poolStatus.value = PoolStatus(
            phase: 'discovering',
            discoveryDepth: intermediate.depth,
            discoveryNodes: intermediate.nodes,
            discoveryNps: intermediate.nps,
            activeWorkers: _workers.length,
            hashPerWorkerMb: _lastHashPerWorkerMb,
          );
        },
      );

      if (_generation != myGen) return const DiscoveryResult();

      discoveryResult.value = result;
      if (kDebugMode) {
        print('[Pool] Discovery DONE — ${result.lines.length} lines, '
            'depth ${result.depth}');
      }
      return result;
    } catch (e) {
      if (_generation != myGen) return const DiscoveryResult();
      if (kDebugMode) print('[Pool] Discovery FAILED: $e');
      return const DiscoveryResult();
    }
  }

  // ── Evaluation: per-move deep eval + ease ───────────────────────────

  /// Evaluate a fixed list of moves. Workers start immediately.
  /// Results stream to [results]; status to [poolStatus].
  Future<void> startEvaluation({
    required String baseFen,
    required List<String> moveUcis,
    required int evalDepth,
    required int easeDepth,
  }) async {
    _generation++;
    final myGen = _generation;

    // Cancel in-progress evals
    for (final w in _workers) {
      w.stop();
    }

    _currentBaseFen = baseFen;
    _moveQueue = List.from(moveUcis);
    _nextMoveIndex = 0;
    _workerCurrentMoves.clear();
    results.value = {};

    if (moveUcis.isEmpty) {
      poolStatus.value = const PoolStatus(
        phase: 'complete',
        totalMoves: 0,
        completedMoves: 0,
      );
      return;
    }

    poolStatus.value = PoolStatus(
      phase: 'evaluating',
      totalMoves: moveUcis.length,
      activeWorkers: _workers.length,
      hashPerWorkerMb: _lastHashPerWorkerMb,
    );

    final settings = EngineSettings();
    _evalDepth = evalDepth;
    _easeDepth = easeDepth;
    _maxLoadPercent = settings.maxSystemLoad.toDouble();
    _targetMaxWorkers = settings.cores;

    // Ensure workers exist (in case discovery was skipped)
    if (_workers.isEmpty) {
      await _ensureWorkers(
        maxLoadPercent: _maxLoadPercent,
        maxWorkers: _targetMaxWorkers,
      );
      if (_generation != myGen || _workers.isEmpty) {
        poolStatus.value = PoolStatus(
          phase: 'complete',
          totalMoves: moveUcis.length,
          completedMoves: 0,
        );
        return;
      }
    } else {
      // Workers already running — rebalance hash for current RAM headroom
      _rebalanceHash();
    }

    if (kDebugMode) {
      print('[Pool] Evaluation START — ${moveUcis.length} moves, '
          'depth=$evalDepth, ease=$easeDepth, '
          'workers=${_workers.length}/$_targetMaxWorkers, '
          'hash=${_lastHashPerWorkerMb} MB/worker');
    }

    _startWorkerLoops(myGen);
    _startScaleUpLoop(myGen);
  }

  /// Cancel all in-progress work. Workers stay alive.
  void cancel() {
    _generation++;
    _workerCurrentMoves.clear();
    _currentBaseFen = null;
    _moveQueue = [];
    _nextMoveIndex = 0;
    for (final w in _workers) {
      w.stop();
    }
    discoveryResult.value = const DiscoveryResult();
    results.value = {};
    poolStatus.value = const PoolStatus();
  }

  // ── Worker loop (simple queue — no incremental waiting) ─────────────

  String? _getNextMove() {
    if (_nextMoveIndex >= _moveQueue.length) return null;
    return _moveQueue[_nextMoveIndex++];
  }

  void _emitPoolStatus() {
    poolStatus.value = PoolStatus(
      phase: 'evaluating',
      evaluatingUcis: _workerCurrentMoves.values.toList(),
      totalMoves: _moveQueue.length,
      completedMoves: results.value.length,
      activeWorkers: _workers.length,
      hashPerWorkerMb: _lastHashPerWorkerMb,
    );
  }

  void _startWorkerLoops(int generation) {
    if (_workers.isEmpty) return;

    final futures = <Future<void>>[];
    for (int i = 0; i < _workers.length; i++) {
      futures.add(_workerLoop(_workers[i], i, generation));
    }

    Future.wait(futures).then((_) {
      if (_generation == generation) {
        _workerCurrentMoves.clear();
        poolStatus.value = PoolStatus(
          phase: 'complete',
          totalMoves: _moveQueue.length,
          completedMoves: results.value.length,
          activeWorkers: _workers.length,
          hashPerWorkerMb: _lastHashPerWorkerMb,
        );
      }
    });
  }

  Future<void> _workerLoop(
    EvalWorker worker,
    int workerIndex,
    int generation,
  ) async {
    final baseFen = _currentBaseFen;
    if (baseFen == null) return;

    final fenParts = baseFen.split(' ');
    final isWhiteToMove = fenParts.length >= 2 && fenParts[1] == 'w';

    while (_generation == generation) {
      final uci = _getNextMove();
      if (uci == null) break; // queue empty

      _workerCurrentMoves[workerIndex] = uci;
      _emitPoolStatus();

      try {
        final resultingFen = playUciMove(baseFen, uci);
        if (resultingFen == null) continue;

        // ── Eval ──
        final eval = await worker.evaluateFen(resultingFen, _evalDepth);
        if (_generation != generation) return;

        // Convert to White perspective
        final whiteCp = eval.scoreCp != null
            ? (isWhiteToMove ? -eval.scoreCp! : eval.scoreCp!)
            : null;
        final whiteMate = eval.scoreMate != null
            ? (isWhiteToMove ? -eval.scoreMate! : eval.scoreMate!)
            : null;
        final fullPv = [uci, ...eval.pv];

        _emitResult(
          uci,
          MoveAnalysisResult(
            scoreCp: whiteCp,
            scoreMate: whiteMate,
            pv: fullPv,
            depth: eval.depth,
          ),
        );
        _emitPoolStatus();

        // ── Ease ──
        double? ease;
        try {
          ease = await _computeMoveEase(
              worker, resultingFen, eval, _easeDepth, generation);
        } catch (_) {}
        if (_generation != generation) return;

        _emitResult(
          uci,
          MoveAnalysisResult(
            scoreCp: whiteCp,
            scoreMate: whiteMate,
            pv: fullPv,
            depth: eval.depth,
            moveEase: ease,
          ),
        );
      } catch (_) {
        if (_generation != generation) return;
      } finally {
        _workerCurrentMoves.remove(workerIndex);
        _emitPoolStatus();
      }
    }
  }

  void _emitResult(String uci, MoveAnalysisResult result) {
    final updated = Map<String, MoveAnalysisResult>.from(results.value);
    updated[uci] = result;
    results.value = updated;
  }

  // ── Ease computation ────────────────────────────────────────────────

  Future<double?> _computeMoveEase(
    EvalWorker worker,
    String fen,
    EvalResult rootEval,
    int depth,
    int generation,
  ) async {
    final candidates = <MapEntry<String, double>>[];
    final dbData = await _probabilityService.getProbabilitiesForFen(fen);
    if (dbData != null && dbData.moves.isNotEmpty) {
      final sortedDb = dbData.moves.toList()
        ..sort((a, b) => b.probability.compareTo(a.probability));

      double cumulativeProb = 0.0;
      for (final move in sortedDb) {
        if (move.uci.isEmpty) continue;
        final prob = move.probability / 100.0;
        if (prob < 0.01) continue;
        candidates.add(MapEntry(move.uci, prob));
        cumulativeProb += prob;
        if (cumulativeProb > 0.90) break;
      }

      // Use DB only when every move in the selected probability mass has
      // enough support (>50 games). Otherwise, fall back to Maia.
      final hasReliableDbMass = candidates.isNotEmpty &&
          candidates.every((entry) {
            for (final move in sortedDb) {
              if (move.uci == entry.key) return move.total > 50;
            }
            return false;
          });
      if (!hasReliableDbMass) {
        candidates.clear();
      }
    }

    if (candidates.isEmpty) {
      if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
        return null;
      }
      final maiaProbs = await MaiaFactory.instance!.evaluate(fen, 1900);
      if (maiaProbs.isEmpty) return null;

      final sortedMaia = maiaProbs.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      double cumulativeProb = 0.0;
      for (final entry in sortedMaia) {
        if (entry.value < 0.01) continue;
        candidates.add(entry);
        cumulativeProb += entry.value;
        if (cumulativeProb > 0.90) break;
      }
    }

    if (candidates.isEmpty) return null;

    final maxQ = scoreToQ(rootEval.effectiveCp);
    double sumWeightedRegret = 0.0;
    final game = chess.Chess.fromFEN(fen);

    for (final entry in candidates) {
      if (_generation != generation) return null;

      final candidateUci = entry.key;
      final prob = entry.value;

      final from = candidateUci.substring(0, 2);
      final to = candidateUci.substring(2, 4);
      String? promotion;
      if (candidateUci.length > 4) promotion = candidateUci.substring(4);

      if (!game.move({'from': from, 'to': to, 'promotion': promotion})) {
        continue;
      }
      final nextFen = game.fen;
      game.undo();

      final candidateEval = await worker.evaluateFen(nextFen, depth);

      final score = -candidateEval.effectiveCp;
      final qVal = scoreToQ(score);

      final regret = math.max(0.0, maxQ - qVal);
      sumWeightedRegret += math.pow(prob, kEaseBeta) * regret;
    }

    return 1.0 - math.pow(sumWeightedRegret / 2, kEaseAlpha);
  }

  /// Dispose all workers and reset.
  void dispose() {
    cancel();
    _disposeAllWorkers();
  }
}
