/// Whether a move that is not the stored answer deserves the point anyway.
///
/// A mined puzzle keeps one line — the engine's first choice at mine time —
/// but positions often have two moves that win the same material, and a
/// trainer that marks the second one wrong teaches the wrong lesson. With the
/// session option on, the controller hands a non-matching move here; the
/// engine scores the position after it and after the stored answer, and
/// [isAcceptableAlternative] decides. The rule is deliberately narrow: the
/// played move must hold at least as much as the answer, within half a pawn.
/// A slower mate passes (mate scores sit a few points apart); giving up a
/// mate for a won endgame does not — the puzzle was the mate.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../../services/engine/engine_lifecycle.dart';
import '../../../services/engine/stockfish_connection_factory.dart';
import '../../../services/engine/stockfish_pool.dart';

/// One move to judge: the position it was played in, the move, and the
/// stored answer at that point of the line (SAN or UCI, as stored).
class AlternativeMoveQuery {
  const AlternativeMoveQuery({
    required this.fen,
    required this.playedUci,
    required this.bestToken,
  });

  final String fen;
  final String playedUci;
  final String bestToken;
}

/// Answers "is this move just as good as the stored answer?". `false` is
/// also the answer when the question cannot be asked — no engine, engine
/// busy, a move that does not parse — so the caller only ever sees a verdict.
typedef AlternativeMoveJudge =
    Future<bool> Function(AlternativeMoveQuery query);

/// Largest eval drop, in centipawns, a move may show against the stored
/// answer and still count. Both evals are from the mover's point of view.
const int kAlternativeToleranceCp = 50;

/// The rule, on its own so it can be tested without an engine.
bool isAcceptableAlternative({
  required int playedCp,
  required int bestCp,
  int toleranceCp = kAlternativeToleranceCp,
}) => playedCp >= bestCp - toleranceCp;

/// The engine-backed judge the app wires in. [evaluate] defaults to the
/// shared Stockfish pool; tests pass a canned scorer.
class EngineAlternativeJudge {
  EngineAlternativeJudge({
    Future<EvalResult> Function(String fen, int depth)? evaluate,
    Future<bool> Function()? engineReady,
    this.depth = defaultDepth,
    this.timeout = const Duration(seconds: 10),
  }) : _evaluate = evaluate ?? _poolEvaluate,
       _engineReady = engineReady ?? _poolReady;

  /// Deep enough to tell a real alternative from a trap in a tactical
  /// position, shallow enough to answer in well under the time a wrong move
  /// dwells on the board. Same depth the miner uses when Maia disagrees.
  static const int defaultDepth = 14;

  final Future<EvalResult> Function(String fen, int depth) _evaluate;
  final Future<bool> Function() _engineReady;
  final int depth;
  final Duration timeout;

  static Future<EvalResult> _poolEvaluate(String fen, int depth) =>
      StockfishPool.instance.evaluateFen(fen, depth);

  /// One worker is plenty for two evals; a repertoire build that holds the
  /// engine wins, as it does for every other engine consumer.
  static Future<bool> _poolReady() async {
    if (!StockfishConnectionFactory.isAvailable) return false;
    if (EngineLifecycle.instance.state == EngineState.generating) return false;
    await StockfishPool.instance.ensureWorkers(1);
    return StockfishPool.instance.workerCount > 0;
  }

  Future<bool> judge(AlternativeMoveQuery query) async {
    try {
      final pos = Chess.fromSetup(Setup.parseFen(query.fen));
      final played = Move.parse(query.playedUci);
      if (played == null || !pos.isLegal(played)) return false;
      final best = _parseToken(pos, query.bestToken);
      if (best == null) return false;
      if (best == played) return true;
      if (!await _engineReady()) return false;

      final results = await Future.wait([
        _evaluate(pos.play(played).fen, depth),
        _evaluate(pos.play(best).fen, depth),
      ]).timeout(timeout);
      // The engine scores for the side to move, which after either move is
      // the opponent; negate to see both through the mover's eyes.
      return isAcceptableAlternative(
        playedCp: -results[0].effectiveCp,
        bestCp: -results[1].effectiveCp,
      );
    } catch (e) {
      debugPrint('[AlternativeMoveJudge] Could not judge move: $e');
      return false;
    }
  }

  static Move? _parseToken(Position pos, String token) {
    final trimmed = token.trim();
    if (RegExp(r'^[a-h][1-8][a-h][1-8][qrbnQRBN]?$').hasMatch(trimmed)) {
      return Move.parse(trimmed.toLowerCase());
    }
    return pos.parseSan(trimmed);
  }
}
