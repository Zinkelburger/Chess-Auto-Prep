/// Interactive analysis pipeline for the engine pane.
///
/// Orchestrates: discovery (MultiPV) -> candidate filtering -> per-move
/// eval.  Uses [StockfishPool] for Stockfish workers and exposes
/// [ValueNotifier]s for the UI to subscribe to.
///
/// Replaces the old [MoveAnalysisPool] for the interactive analysis use case.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'engine/stockfish_pool.dart';
import 'engine/eval_worker.dart';
import '../models/analysis/move_analysis_result.dart';
import '../utils/chess_utils.dart' show playUciMove;
import '../utils/fen_utils.dart';

export '../models/analysis/discovery_result.dart';
export '../models/analysis/move_analysis_result.dart';
export '../utils/ease_utils.dart' show scoreToQ, kEaseAlpha, kEaseBeta;
export 'engine/eval_worker.dart' show EvalResult;

class AnalysisService {
  /// Application-wide shared instance.
  static final AnalysisService instance = AnalysisService._();

  /// Create an independent instance (unit tests only).
  @visibleForTesting
  AnalysisService.fresh() : this._();

  AnalysisService._();

  final StockfishPool _pool = StockfishPool.instance;

  int _generation = 0;

  String? _currentBaseFen;
  List<String> _moveQueue = [];
  int _nextMoveIndex = 0;
  int _evalDepth = 20;

  final Map<int, String> _workerCurrentMoves = {};

  // ── Public notifiers ──────────────────────────────────────────────────
  final ValueNotifier<DiscoveryResult> discoveryResult = ValueNotifier(
    const DiscoveryResult(),
  );
  final ValueNotifier<Map<String, MoveAnalysisResult>> results = ValueNotifier(
    {},
  );
  final ValueNotifier<PoolStatus> poolStatus = ValueNotifier(
    const PoolStatus(),
  );

  int get workerCount => _pool.workerCount;

  /// Applies [apply] synchronously when idle; otherwise after the current frame.
  /// Avoids "widget tree was locked" when notifiers rebuild [ListenableBuilder]s.
  void _publishUi(void Function() apply) {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      apply();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    }
  }

  // ── Engine-pane priority gate ─────────────────────────────────────────
  //
  // On-the-fly expectimax shares [StockfishPool] with the interactive engine
  // pane.  The pane calls [beginEnginePaneAnalysis] while its full pipeline
  // (Maia + DB + discovery + per-move eval) runs; expectimax waits via
  // [waitForEnginePaneAnalysis] so Stockfish serves the current position first.

  String? _enginePaneFen;
  Completer<void>? _enginePaneDone;

  void beginEnginePaneAnalysis(String fen) {
    if (_enginePaneFen == fen &&
        _enginePaneDone != null &&
        !_enginePaneDone!.isCompleted) {
      return;
    }
    endEnginePaneAnalysis();
    _enginePaneFen = fen;
    _enginePaneDone = Completer<void>();
    if (kDebugMode) {
      debugPrint(
        '[Analysis] Engine-pane pipeline BLOCKING expectimax for '
        '${fen.split(' ').take(2).join(' ')}',
      );
    }
  }

  void endEnginePaneAnalysis([String? fen]) {
    if (fen != null && _enginePaneFen != null && _enginePaneFen != fen) {
      return;
    }
    final blockedFen = _enginePaneFen;
    _enginePaneFen = null;
    final done = _enginePaneDone;
    _enginePaneDone = null;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
    if (kDebugMode && blockedFen != null) {
      debugPrint('[Analysis] Engine-pane pipeline DONE — expectimax may run');
    }
  }

  Future<void> waitForEnginePaneAnalysis(String fen) async {
    // The engine pane registers its gate synchronously before starting work;
    // poll briefly in case of minor scheduling skew.
    const poll = Duration(milliseconds: 16);
    const maxWait = Duration(milliseconds: 200);
    // Yield-only, not a hard dependency: the pane's full pipeline (discovery
    // + per-move deep evals) can run for a minute or stall outright, and
    // expectimax must never be held hostage by it — the pool serializes
    // worker access anyway.  Give the pane a short head start, then go.
    const maxGateWait = Duration(seconds: 3);
    final deadline = DateTime.now().add(maxWait);

    while (DateTime.now().isBefore(deadline)) {
      if (_enginePaneFen == fen) {
        final done = _enginePaneDone;
        if (done != null) {
          if (kDebugMode) {
            debugPrint(
              '[Analysis] Expectimax waiting for engine-pane pipeline '
              '(${fen.split(' ').take(2).join(' ')})',
            );
          }
          try {
            await done.future.timeout(maxGateWait);
            if (kDebugMode) {
              debugPrint(
                '[Analysis] Expectimax may proceed — engine-pane done',
              );
            }
          } on TimeoutException {
            if (kDebugMode) {
              debugPrint(
                '[Analysis] Expectimax proceeding — engine-pane '
                'pipeline still busy after ${maxGateWait.inSeconds}s',
              );
            }
          }
          return;
        }
      }
      await Future.delayed(poll);
    }

    if (kDebugMode && _enginePaneFen != fen) {
      debugPrint(
        '[Analysis] Expectimax proceeding without engine-pane gate '
        '(timed out waiting for ${fen.split(' ').take(2).join(' ')})',
      );
    }
  }

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
    _publishUi(() {
      results.value = {};
      discoveryResult.value = const DiscoveryResult();
    });

    await _pool.ensureWorkers();

    if (_generation != myGen || _pool.workerCount == 0) {
      return const DiscoveryResult();
    }

    final whiteToMove = isWhiteToMove(fen);

    _publishUi(() {
      poolStatus.value = PoolStatus(
        phase: 'discovering',
        activeWorkers: _pool.workerCount,
        hashPerWorkerMb: kPoolHashPerWorkerMb,
      );
    });

    if (kDebugMode) {
      debugPrint(
        '[Analysis] Discovery START — MultiPV=$multiPv, depth=$depth, '
        'workers=${_pool.workerCount}, '
        'fen=${fen.split(' ').take(2).join(' ')}',
      );
    }

    var lastLoggedDiscoveryDepth = 0;

    try {
      final result = await _pool.discoverMoves(
        fen: fen,
        depth: depth,
        multiPv: multiPv,
        isWhiteToMove: whiteToMove,
        onProgress: (intermediate) {
          if (_generation != myGen) return;
          _publishUi(() {
            discoveryResult.value = intermediate;
            poolStatus.value = PoolStatus(
              phase: 'discovering',
              discoveryDepth: intermediate.depth,
              discoveryNodes: intermediate.nodes,
              discoveryNps: intermediate.nps,
              activeWorkers: _pool.workerCount,
              hashPerWorkerMb: kPoolHashPerWorkerMb,
            );
          });
          if (kDebugMode &&
              intermediate.depth > lastLoggedDiscoveryDepth &&
              intermediate.lines.isNotEmpty) {
            lastLoggedDiscoveryDepth = intermediate.depth;
            debugPrint(
              '[Analysis] Discovery depth ${intermediate.depth}/$depth '
              '— ${intermediate.lines.length} lines, '
              '${intermediate.nodes} nodes',
            );
          }
        },
      );

      if (_generation != myGen) return const DiscoveryResult();

      _publishUi(() => discoveryResult.value = result);
      if (kDebugMode) {
        debugPrint(
          '[Analysis] Discovery DONE — ${result.lines.length} lines, '
          'depth ${result.depth}',
        );
      }
      return result;
    } catch (e) {
      if (_generation != myGen) return const DiscoveryResult();
      if (kDebugMode) debugPrint('[Analysis] Discovery FAILED: $e');
      return const DiscoveryResult();
    }
  }

  // ── Evaluation: per-move deep eval ─────────────────────────────────────

  Future<void> startEvaluation({
    required String baseFen,
    required List<String> moveUcis,
    required int evalDepth,
  }) async {
    _generation++;
    final myGen = _generation;

    _pool.stopAll();

    _currentBaseFen = baseFen;
    _moveQueue = List.from(moveUcis);
    _nextMoveIndex = 0;
    _workerCurrentMoves.clear();
    _publishUi(() => results.value = {});

    if (moveUcis.isEmpty) {
      _publishUi(() {
        poolStatus.value = const PoolStatus(
          phase: 'complete',
          totalMoves: 0,
          completedMoves: 0,
        );
      });
      return;
    }

    _evalDepth = evalDepth;

    await _pool.ensureWorkers();

    if (_generation != myGen || _pool.workerCount == 0) {
      _publishUi(() {
        poolStatus.value = PoolStatus(
          phase: 'complete',
          totalMoves: moveUcis.length,
          completedMoves: 0,
        );
      });
      return;
    }

    _publishUi(() {
      poolStatus.value = PoolStatus(
        phase: 'evaluating',
        totalMoves: moveUcis.length,
        activeWorkers: _pool.workerCount,
        hashPerWorkerMb: kPoolHashPerWorkerMb,
      );
    });

    if (kDebugMode) {
      debugPrint(
        '[Analysis] Evaluation START — ${moveUcis.length} moves, '
        'depth=$evalDepth, workers=${_pool.workerCount}',
      );
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
    _publishUi(() {
      discoveryResult.value = const DiscoveryResult();
      results.value = {};
      poolStatus.value = const PoolStatus();
    });
    endEnginePaneAnalysis();
  }

  // ── Worker loop ───────────────────────────────────────────────────────

  String? _getNextMove() {
    if (_nextMoveIndex >= _moveQueue.length) return null;
    return _moveQueue[_nextMoveIndex++];
  }

  void _emitPoolStatus() {
    _publishUi(() {
      poolStatus.value = PoolStatus(
        phase: 'evaluating',
        evaluatingUcis: _workerCurrentMoves.values.toList(),
        totalMoves: _moveQueue.length,
        completedMoves: results.value.length,
        activeWorkers: _pool.workerCount,
        hashPerWorkerMb: kPoolHashPerWorkerMb,
      );
    });
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
        _publishUi(() {
          poolStatus.value = PoolStatus(
            phase: 'complete',
            totalMoves: _moveQueue.length,
            completedMoves: results.value.length,
            activeWorkers: _pool.workerCount,
            hashPerWorkerMb: kPoolHashPerWorkerMb,
          );
        });
      }
    });
  }

  Future<void> _workerLoop(int workerIndex, int generation) async {
    final baseFen = _currentBaseFen;
    if (baseFen == null) return;

    final whiteToMove = isWhiteToMove(baseFen);

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
            ? (whiteToMove ? -eval.scoreCp! : eval.scoreCp!)
            : null;
        final whiteMate = eval.scoreMate != null
            ? (whiteToMove ? -eval.scoreMate! : eval.scoreMate!)
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
      } catch (e) {
        if (_generation != generation) return;
        if (kDebugMode) {
          debugPrint('[Analysis] Evaluation FAILED for $uci: $e');
        }
      } finally {
        if (worker != null) _pool.release(worker);
        _workerCurrentMoves.remove(workerIndex);
        _emitPoolStatus();
      }
    }
  }

  void _emitResult(String uci, MoveAnalysisResult result) {
    _publishUi(() {
      final updated = Map<String, MoveAnalysisResult>.from(results.value);
      updated[uci] = result;
      results.value = updated;
    });
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────

  void dispose() {
    cancel();
    _pool.dispose();
  }
}
