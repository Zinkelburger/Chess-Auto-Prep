/// Interactive analysis pipeline for the engine pane.
///
/// Orchestrates: discovery (MultiPV) -> candidate filtering -> per-move
/// eval. Uses one shared [BoardEngine] with the selected threads and exposes
/// [ValueNotifier]s for the UI to subscribe to.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../models/analysis/discovery_result.dart';
import '../models/analysis/move_analysis_result.dart';
import '../utils/chess_utils.dart' show playUciMove;
import '../utils/fen_utils.dart';
import 'engine/board_engine.dart';
import 'engine/eval_worker.dart' show EvalResult;

export '../models/analysis/discovery_result.dart';
export '../models/analysis/move_analysis_result.dart';
export '../utils/ease_utils.dart' show scoreToQ, kEaseAlpha, kEaseBeta;
export 'engine/eval_worker.dart' show EvalResult;

class AnalysisService {
  AnalysisService({BoardEngine? engine})
    : _engine = engine ?? BoardEngine.instance,
      _session = (engine ?? BoardEngine.instance).createSession();

  final BoardEngine _engine;
  final BoardEngineSession _session;
  bool _disposed = false;

  /// Bumped by every new request and by [cancel]; work started under an
  /// older generation publishes nothing.
  int _generation = 0;

  String? _currentBaseFen;
  List<String> _moveQueue = [];
  int _nextMoveIndex = 0;
  int _evalDepth = 20;

  /// The candidate the evaluation loop is on right now, if any.
  String? _evaluatingUci;

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
    final generation = _generation;
    void publish() {
      if (!_disposed && generation == _generation) apply();
    }

    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      publish();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => publish());
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  /// A [PoolStatus] for [phase] carrying the engine's current worker count
  /// and hash size.
  PoolStatus _status(
    PoolPhase phase, {
    List<String> evaluatingUcis = const [],
    int totalMoves = 0,
    int completedMoves = 0,
    int discoveryDepth = 0,
    int discoveryNodes = 0,
    int discoveryNps = 0,
  }) => PoolStatus(
    phase: phase,
    evaluatingUcis: evaluatingUcis,
    totalMoves: totalMoves,
    completedMoves: completedMoves,
    activeWorkers: _engine.workerCount,
    hashPerWorkerMb: _engine.effectiveSettings.hashMb,
    discoveryDepth: discoveryDepth,
    discoveryNodes: discoveryNodes,
    discoveryNps: discoveryNps,
  );

  Future<void> prepare() => _session.prepare();

  void detach() {
    cancel();
    _session.detach();
  }

  // ── Discovery: MultiPV on root position ───────────────────────────────

  Future<DiscoveryResult> runDiscovery({
    required String fen,
    required int depth,
    required int multiPv,
  }) async {
    final myGen = ++_generation;

    _session.pause();
    _evaluatingUci = null;
    _currentBaseFen = null;
    _publishUi(() {
      results.value = {};
      discoveryResult.value = const DiscoveryResult();
      poolStatus.value = _status(PoolPhase.discovering);
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
      final result = await _session.discover(
        fen: fen,
        depth: depth,
        multiPv: multiPv,
        whiteToMove: isWhiteToMove(fen),
        onProgress: (intermediate) {
          if (_generation != myGen) return;
          _publishUi(() {
            discoveryResult.value = intermediate;
            poolStatus.value = _status(
              PoolPhase.discovering,
              discoveryDepth: intermediate.depth,
              discoveryNodes: intermediate.nodes,
              discoveryNps: intermediate.nps,
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
      if (kDebugMode && _generation == myGen) {
        debugPrint('[Analysis] Discovery FAILED: $e');
      }
      return const DiscoveryResult();
    }
  }

  // ── Evaluation: per-move deep eval ─────────────────────────────────────

  Future<void> startEvaluation({
    required String baseFen,
    required List<String> moveUcis,
    required int evalDepth,
  }) async {
    final myGen = ++_generation;

    _session.pause();

    _currentBaseFen = baseFen;
    _moveQueue = List.of(moveUcis);
    _nextMoveIndex = 0;
    _evaluatingUci = null;
    _publishUi(() => results.value = {});

    if (moveUcis.isEmpty) {
      _publishUi(
        () => poolStatus.value = const PoolStatus(phase: PoolPhase.complete),
      );
      return;
    }

    _evalDepth = evalDepth;

    _publishUi(() {
      poolStatus.value = _status(
        PoolPhase.evaluating,
        totalMoves: moveUcis.length,
      );
    });

    if (kDebugMode) {
      debugPrint(
        '[Analysis] Evaluation START — ${moveUcis.length} moves, '
        'depth=$evalDepth, workers=${_engine.workerCount}',
      );
    }

    unawaited(_runEvaluationQueue(myGen));
  }

  void cancel() {
    _generation++;
    _evaluatingUci = null;
    _currentBaseFen = null;
    _moveQueue = [];
    _nextMoveIndex = 0;
    _session.pause();
    _publishUi(() {
      discoveryResult.value = const DiscoveryResult();
      results.value = {};
      poolStatus.value = const PoolStatus();
    });
  }

  // ── Evaluation loop ───────────────────────────────────────────────────

  String? _takeNextMove() {
    if (_nextMoveIndex >= _moveQueue.length) return null;
    return _moveQueue[_nextMoveIndex++];
  }

  void _emitEvaluatingStatus() {
    _publishUi(() {
      poolStatus.value = _status(
        PoolPhase.evaluating,
        evaluatingUcis: [?_evaluatingUci],
        totalMoves: _moveQueue.length,
        completedMoves: results.value.length,
      );
    });
  }

  Future<void> _runEvaluationQueue(int generation) async {
    await _evaluateQueuedMoves(generation);
    if (_generation != generation) return;
    _evaluatingUci = null;
    _publishUi(() {
      poolStatus.value = _status(
        PoolPhase.complete,
        totalMoves: _moveQueue.length,
        completedMoves: results.value.length,
      );
    });
  }

  Future<void> _evaluateQueuedMoves(int generation) async {
    final baseFen = _currentBaseFen;
    if (baseFen == null) return;

    final whiteToMove = isWhiteToMove(baseFen);

    while (_generation == generation) {
      final uci = _takeNextMove();
      if (uci == null) break;

      _evaluatingUci = uci;
      _emitEvaluatingStatus();

      try {
        final resultingFen = playUciMove(baseFen, uci);
        if (resultingFen == null) continue;

        final eval = await _session.evaluate(resultingFen, _evalDepth);
        if (_generation != generation || eval == null) return;

        _emitResult(uci, _whiteRelativeResult(uci, eval, whiteToMove));
        _emitEvaluatingStatus();
      } catch (e) {
        if (_generation != generation) return;
        if (kDebugMode) {
          debugPrint('[Analysis] Evaluation FAILED for $uci: $e');
        }
      } finally {
        // A cancel or a newer request has already published its own status
        // and may have started its own loop; a stale loop unwinding must
        // not clear the new entry or overwrite that status.
        if (_evaluatingUci == uci) _evaluatingUci = null;
        if (_generation == generation) _emitEvaluatingStatus();
      }
    }
  }

  /// [eval] scores the position *after* [uci] from that side's point of
  /// view; the result is keyed by [uci] and expressed for White.
  static MoveAnalysisResult _whiteRelativeResult(
    String uci,
    EvalResult eval,
    bool whiteToMove,
  ) {
    final cp = eval.scoreCp;
    final whiteCp = cp == null ? null : (whiteToMove ? -cp : cp);
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
    return MoveAnalysisResult(
      scoreCp: whiteCp,
      scoreMate: whiteMate,
      pv: [uci, ...eval.pv],
      depth: eval.depth,
    );
  }

  void _emitResult(String uci, MoveAnalysisResult result) {
    _publishUi(() {
      results.value = {...results.value, uci: result};
    });
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────

  void dispose() {
    if (_disposed) return;
    cancel();
    _disposed = true;
    _session.dispose();
    discoveryResult.dispose();
    results.dispose();
    poolStatus.dispose();
  }
}
