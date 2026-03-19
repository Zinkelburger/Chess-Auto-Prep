/// Interactive analysis pipeline for the engine pane.
///
/// Orchestrates: discovery (MultiPV) -> candidate filtering -> per-move
/// eval + ease.  Uses [StockfishPool] for Stockfish workers and exposes
/// [ValueNotifier]s for the UI to subscribe to.
///
/// Replaces the old [MoveAnalysisPool] for the interactive analysis use case.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';

import 'ease_calculator.dart';
import 'engine/stockfish_pool.dart';
import 'engine/eval_worker.dart';
import 'probability_service.dart';
import '../models/analysis/move_analysis_result.dart';
import '../models/engine_settings.dart';
import '../utils/chess_utils.dart' show playUciMove;

export '../models/analysis/discovery_result.dart';
export '../models/analysis/move_analysis_result.dart';
export '../utils/ease_utils.dart'
    show scoreToQ, kEaseAlpha, kEaseBeta, kEaseDisplayScale;
export 'engine/eval_worker.dart' show EvalResult;

class AnalysisService {
  static final AnalysisService _instance = AnalysisService._();
  factory AnalysisService() => _instance;
  AnalysisService._();

  final StockfishPool _pool = StockfishPool();

  int _generation = 0;

  String? _currentBaseFen;
  List<String> _moveQueue = [];
  int _nextMoveIndex = 0;
  int _evalDepth = 20;
  int _easeDepth = 12;

  final Map<int, String> _workerCurrentMoves = {};
  final ProbabilityService _probabilityService = ProbabilityService();

  // ── Public notifiers ──────────────────────────────────────────────────
  final ValueNotifier<DiscoveryResult> discoveryResult =
      ValueNotifier(const DiscoveryResult());
  final ValueNotifier<Map<String, MoveAnalysisResult>> results =
      ValueNotifier({});
  final ValueNotifier<PoolStatus> poolStatus =
      ValueNotifier(const PoolStatus());

  int get workerCount => _pool.workerCount;

  // ── Warm-up ───────────────────────────────────────────────────────────

  Future<void> warmUp() async {
    await _pool.warmUp();
  }

  // ── Discovery: MultiPV on root position ───────────────────────────────

  Future<DiscoveryResult> runDiscovery({
    required String fen,
    required int depth,
    required int multiPv,
  }) async {
    _generation++;
    final myGen = _generation;

    _pool.stopAll();
    _workerCurrentMoves.clear();
    _currentBaseFen = null;
    results.value = {};
    discoveryResult.value = const DiscoveryResult();

    await _pool.ensureWorkers();

    if (_generation != myGen || _pool.workerCount == 0) {
      return const DiscoveryResult();
    }

    final fenParts = fen.split(' ');
    final isWhiteToMove = fenParts.length >= 2 && fenParts[1] == 'w';

    poolStatus.value = PoolStatus(
      phase: 'discovering',
      activeWorkers: _pool.workerCount,
      hashPerWorkerMb: kPoolHashPerWorkerMb,
    );

    if (kDebugMode) {
      print('[Analysis] Discovery START — MultiPV=$multiPv, depth=$depth, '
          'workers=${_pool.workerCount}');
    }

    try {
      final result = await _pool.discoverMoves(
        fen: fen,
        depth: depth,
        multiPv: multiPv,
        isWhiteToMove: isWhiteToMove,
        onProgress: (intermediate) {
          if (_generation != myGen) return;
          discoveryResult.value = intermediate;
          poolStatus.value = PoolStatus(
            phase: 'discovering',
            discoveryDepth: intermediate.depth,
            discoveryNodes: intermediate.nodes,
            discoveryNps: intermediate.nps,
            activeWorkers: _pool.workerCount,
            hashPerWorkerMb: kPoolHashPerWorkerMb,
          );
        },
      );

      if (_generation != myGen) return const DiscoveryResult();

      discoveryResult.value = result;
      if (kDebugMode) {
        print('[Analysis] Discovery DONE — ${result.lines.length} lines, '
            'depth ${result.depth}');
      }
      return result;
    } catch (e) {
      if (_generation != myGen) return const DiscoveryResult();
      if (kDebugMode) print('[Analysis] Discovery FAILED: $e');
      return const DiscoveryResult();
    }
  }

  // ── Evaluation: per-move deep eval + ease ─────────────────────────────

  Future<void> startEvaluation({
    required String baseFen,
    required List<String> moveUcis,
    required int evalDepth,
    required int easeDepth,
  }) async {
    _generation++;
    final myGen = _generation;

    _pool.stopAll();

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

    _evalDepth = evalDepth;
    _easeDepth = easeDepth;

    await _pool.ensureWorkers();

    if (_generation != myGen || _pool.workerCount == 0) {
      poolStatus.value = PoolStatus(
        phase: 'complete',
        totalMoves: moveUcis.length,
        completedMoves: 0,
      );
      return;
    }

    poolStatus.value = PoolStatus(
      phase: 'evaluating',
      totalMoves: moveUcis.length,
      activeWorkers: _pool.workerCount,
      hashPerWorkerMb: kPoolHashPerWorkerMb,
    );

    if (kDebugMode) {
      print('[Analysis] Evaluation START — ${moveUcis.length} moves, '
          'depth=$evalDepth, ease=$easeDepth, '
          'workers=${_pool.workerCount}');
    }

    _startWorkerLoops(myGen);
  }

  void cancel() {
    _generation++;
    _workerCurrentMoves.clear();
    _currentBaseFen = null;
    _moveQueue = [];
    _nextMoveIndex = 0;
    _pool.stopAll();
    discoveryResult.value = const DiscoveryResult();
    results.value = {};
    poolStatus.value = const PoolStatus();
  }

  // ── Worker loop ───────────────────────────────────────────────────────

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
      activeWorkers: _pool.workerCount,
      hashPerWorkerMb: kPoolHashPerWorkerMb,
    );
  }

  void _startWorkerLoops(int generation) {
    final workerCount = _pool.workerCount;
    if (workerCount == 0) return;

    final futures = <Future<void>>[];
    for (int i = 0; i < workerCount; i++) {
      futures.add(_workerLoop(i, generation));
    }

    Future.wait(futures).then((_) {
      if (_generation == generation) {
        _workerCurrentMoves.clear();
        poolStatus.value = PoolStatus(
          phase: 'complete',
          totalMoves: _moveQueue.length,
          completedMoves: results.value.length,
          activeWorkers: _pool.workerCount,
          hashPerWorkerMb: kPoolHashPerWorkerMb,
        );
      }
    });
  }

  Future<void> _workerLoop(int workerIndex, int generation) async {
    final baseFen = _currentBaseFen;
    if (baseFen == null) return;

    final fenParts = baseFen.split(' ');
    final isWhiteToMove = fenParts.length >= 2 && fenParts[1] == 'w';

    while (_generation == generation) {
      final uci = _getNextMove();
      if (uci == null) break;

      _workerCurrentMoves[workerIndex] = uci;
      _emitPoolStatus();

      EvalWorker? worker;
      try {
        worker = await _pool.acquire();
        if (_generation != generation) return;

        final resultingFen = playUciMove(baseFen, uci);
        if (resultingFen == null) continue;

        // ── Eval ──
        final eval = await worker.evaluateFen(resultingFen, _evalDepth);
        if (_generation != generation) return;

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
        if (worker != null) _pool.release(worker);
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

  // ── Ease computation ──────────────────────────────────────────────────

  Future<double?> _computeMoveEase(
    EvalWorker worker,
    String fen,
    EvalResult rootEval,
    int depth,
    int generation,
  ) async {
    final dbData = await _probabilityService.getProbabilitiesForFen(fen);

    return EaseCalculator.compute(
      fen: fen,
      evalDepth: depth,
      maiaElo: EngineSettings().maiaElo,
      dbData: dbData,
      evaluateBatch: (fens, d) async {
        final results = <EvalResult>[];
        for (final f in fens) {
          if (_generation != generation) {
            throw StateError('Generation changed');
          }
          results.add(await worker.evaluateFen(f, d));
        }
        return results;
      },
    );
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────

  void dispose() {
    cancel();
    _pool.dispose();
  }
}
