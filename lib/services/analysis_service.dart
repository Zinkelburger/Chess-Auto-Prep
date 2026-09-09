/// Interactive analysis pipeline for the engine pane.
///
/// Orchestrates: discovery (MultiPV) -> candidate filtering -> per-move
/// eval. Uses one shared [BoardEngine] with the selected threads and exposes
/// [ValueNotifier]s for the UI to subscribe to.
///
/// Replaces the old [MoveAnalysisPool] for the interactive analysis use case.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../models/engine_settings.dart';
import '../models/analysis/discovery_result.dart';
import 'engine/board_engine.dart';
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
  AnalysisService.fresh({BoardEngine? engine})
    : _engine = engine ?? BoardEngine.instance;

  AnalysisService._() : _engine = BoardEngine.instance;

  final BoardEngine _engine;

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

  int get workerCount => _engine.workerCount;

  /// Applies [apply] synchronously when idle; otherwise after the current frame.
  /// Avoids "widget tree was locked" when notifiers rebuild [ListenableBuilder]s.
  void _publishUi(void Function() apply) {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      apply();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    }
  }

  Future<void> prepare(Object pane) => _engine.prepare(pane);

  void detach(Object pane) => _engine.detach(pane);

  // ── Discovery: MultiPV on root position ───────────────────────────────

  Future<DiscoveryResult> runDiscovery({
    required String fen,
    required int depth,
    required int multiPv,
  }) async {
    _generation++;
    final myGen = _generation;

    _engine.pause(this);
    _workerCurrentMoves.clear();
    _currentBaseFen = null;
    _publishUi(() {
      results.value = {};
      discoveryResult.value = const DiscoveryResult();
    });

    final whiteToMove = isWhiteToMove(fen);

    _publishUi(() {
      poolStatus.value = PoolStatus(
        phase: 'discovering',
        activeWorkers: _engine.workerCount,
        hashPerWorkerMb: EngineSettings.instance.hashMb,
      );
    });

    if (kDebugMode) {
      debugPrint(
        '[Analysis] Discovery START — MultiPV=$multiPv, depth=$depth, '
        'workers=${_engine.workerCount}, '
        'fen=${fen.split(' ').take(2).join(' ')}',
      );
    }

    var lastLoggedDiscoveryDepth = 0;

    try {
      final result = await _engine.discover(
        this,
        fen: fen,
        depth: depth,
        multiPv: multiPv,
        whiteToMove: whiteToMove,
        onProgress: (intermediate) {
          if (_generation != myGen) return;
          _publishUi(() {
            discoveryResult.value = intermediate;
            poolStatus.value = PoolStatus(
              phase: 'discovering',
              discoveryDepth: intermediate.depth,
              discoveryNodes: intermediate.nodes,
              discoveryNps: intermediate.nps,
              activeWorkers: _engine.workerCount,
              hashPerWorkerMb: EngineSettings.instance.hashMb,
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

      if (_generation != myGen || result == null) {
        return const DiscoveryResult();
      }

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

    _engine.pause(this);

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

    _publishUi(() {
      poolStatus.value = PoolStatus(
        phase: 'evaluating',
        totalMoves: moveUcis.length,
        activeWorkers: _engine.workerCount,
        hashPerWorkerMb: EngineSettings.instance.hashMb,
      );
    });

    if (kDebugMode) {
      debugPrint(
        '[Analysis] Evaluation START — ${moveUcis.length} moves, '
        'depth=$evalDepth, workers=${_engine.workerCount}',
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
    _engine.pause(this);
    _publishUi(() {
      discoveryResult.value = const DiscoveryResult();
      results.value = {};
      poolStatus.value = const PoolStatus();
    });
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
        activeWorkers: _engine.workerCount,
        hashPerWorkerMb: EngineSettings.instance.hashMb,
      );
    });
  }

  void _startWorkerLoops(int generation) {
    unawaited(
      _workerLoop(0, generation).then((_) {
        if (_generation == generation) {
          _workerCurrentMoves.clear();
          _publishUi(() {
            poolStatus.value = PoolStatus(
              phase: 'complete',
              totalMoves: _moveQueue.length,
              completedMoves: results.value.length,
              activeWorkers: _engine.workerCount,
              hashPerWorkerMb: EngineSettings.instance.hashMb,
            );
          });
        }
      }),
    );
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

      try {
        if (_generation != generation) return;

        final resultingFen = playUciMove(baseFen, uci);
        if (resultingFen == null) continue;

        // ── Eval ──
        final eval = await _engine.run(
          this,
          (worker) => worker.evaluateFen(resultingFen, _evalDepth),
        );
        if (_generation != generation || eval == null) return;

        final whiteCp = eval.scoreCp != null
            ? (whiteToMove ? -eval.scoreCp! : eval.scoreCp!)
            : null;
        // `mate 0` is the engine's answer for a checkmated root: the side to
        // move after [uci] is mated, so [uci] delivered it. The distance has
        // no sign to flip, so take it from who moved and count it from the
        // root, mate in 1, the way discovery reports the same move.
        final rawMate = eval.scoreMate;
        final whiteMate = rawMate == null
            ? null
            : rawMate == 0
            ? (whiteToMove ? 1 : -1)
            : (whiteToMove ? -rawMate : rawMate);
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
        // A cancel or a newer request has already published its own status
        // and may have re-used this worker index; a stale loop unwinding must
        // not remove the new entry or overwrite that status.
        if (_workerCurrentMoves[workerIndex] == uci) {
          _workerCurrentMoves.remove(workerIndex);
        }
        if (_generation == generation) _emitPoolStatus();
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
  }
}
