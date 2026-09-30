import 'dart:async';

import '../chess/fen.dart';
import '../chess/generation/sources.dart';
import '../chess/pgn/tree_edit.dart';
import '../diagnostics/log.dart';
import 'engine.dart';
import 'engine_supervisor.dart';
import 'fixed_depth.dart';

sealed class AlternativeVerdict {
  const AlternativeVerdict();
}

final class AlternativeScored extends AlternativeVerdict {
  const AlternativeScored({required this.accepted});
  final bool accepted;
}

final class AlternativeUnavailable extends AlternativeVerdict {
  const AlternativeUnavailable(this.reason);
  final String reason;
}

/// One cancellable comparison on a private, supervised engine. Both positions
/// follow the solver's move, so their scores have the same opponent viewpoint.
final class AlternativeAnswer {
  AlternativeAnswer(this.launch, {this.patience = const Duration(seconds: 30)});

  final Future<EngineStart> Function() launch;
  final Duration patience;
  Engine? _engine;
  bool _cancelled = false;

  Future<AlternativeVerdict> compare({
    required Fen expected,
    required Fen played,
  }) async {
    try {
      return await _compare(expected, played).timeout(patience);
    } catch (error) {
      if (!_cancelled) log.w('Check alternative puzzle answer', error);
      return const AlternativeUnavailable(
        'Stockfish could not finish the check.',
      );
    } finally {
      await cancel();
    }
  }

  Future<AlternativeVerdict> _compare(Fen expected, Fen played) async {
    final expectedPosition = positionOf(expected);
    final playedPosition = positionOf(played);
    if (expectedPosition == null || playedPosition == null) {
      return const AlternativeUnavailable('The position could not be read.');
    }
    if (_cancelled) return const AlternativeUnavailable('Check cancelled.');
    final started = await launch();
    if (started case StartFailed(:final reason)) {
      log.w('Start alternative puzzle engine', reason);
      return AlternativeUnavailable(reason);
    }
    final engine = (started as Started).engine;
    if (_cancelled) {
      await _quit(engine);
      return const AlternativeUnavailable('Check cancelled.');
    }
    _engine = engine;
    final evaluator = FixedDepthEvaluator(engine, depth: 14);
    final stored = await evaluator.evaluate(expectedPosition);
    if (_cancelled) return const AlternativeUnavailable('Check cancelled.');
    if (stored case EvaluationUnavailable(:final reason)) {
      return _unavailable(reason);
    }
    final candidate = await evaluator.evaluate(playedPosition);
    if (candidate case EvaluationUnavailable(:final reason)) {
      return _unavailable(reason);
    }
    // Smaller for the opponent means better for the solver. Allow 50 cp loss.
    return AlternativeScored(
      accepted:
          (candidate as Evaluated).eval.cp <=
          (stored as Evaluated).eval.cp + 50,
    );
  }

  AlternativeUnavailable _unavailable(String reason) {
    log.w('Score alternative puzzle answer', reason);
    return AlternativeUnavailable(reason);
  }

  /// Also covers a launch completing after cancellation or the deadline.
  Future<void> cancel() async {
    _cancelled = true;
    final engine = _engine;
    _engine = null;
    if (engine != null) await _quit(engine);
  }

  Future<void> _quit(Engine engine) async {
    try {
      await engine.quit();
    } catch (error) {
      log.w('Stop alternative puzzle engine', error);
    }
  }
}
