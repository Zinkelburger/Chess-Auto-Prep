import 'dart:math' as math;

import 'package:dartchess/dartchess.dart' show Side;

/// Packed mate scores start here: mate in N is written as ±(10000 − N), so a
/// mate in three is 9997 and a longer mate is a smaller number.
const int mateBaseCp = 10000;

/// A score further from zero than this is a mate, not a material count, and
/// [expectedScore] reads it as a settled game.
const int mateSaturationCp = 9000;

/// Slope of the logistic curve below, shared with the old builder, the C
/// builder and lila, so the three agree on what a centipawn is worth.
const double _winProbSlope = 0.00368208;

/// A fixed-depth engine score in centipawns.
///
/// The type does not carry a point of view; the name of whatever holds one
/// does. [PositionEvaluator] answers from the **side to move**, the way UCI
/// reports `score cp`, and the search converts that once, with [forUs], into
/// the repertoire side's point of view — which is what every field called
/// `evalForUs` holds and what every rule below is written in terms of.
extension type const Eval(int cp) {
  /// This score read by [us], when [sideToMove] is the side it was reported
  /// for. Losing a rook is −500 for the side that lost it whichever side that
  /// is, so one negation is the whole conversion.
  Eval forUs(Side us, Side sideToMove) => us == sideToMove ? this : Eval(-cp);
}

/// The expected score in [0, 1] that the search gives a position worth [eval]
/// centipawns to us: `U(cp) = 1 / (1 + exp(-0.00368208 · cp))`.
///
/// 1 is a win for the repertoire side, 0.5 a draw, 0 a loss, and the curve is
/// symmetric: U(0) = 0.5, U(+100) ≈ 0.591, U(−100) ≈ 0.409. A mate saturates,
/// because the game is decided and no number of centipawns describes it:
/// anything above +9000 is 1 and anything below −9000 is 0.
///
/// This is a bounded estimate of the score we expect from the position, not a
/// calibrated probability that a human wins it.
double expectedScore(Eval eval) {
  if (eval.cp.abs() > mateSaturationCp) return eval.cp > 0 ? 1 : 0;
  return 1 / (1 + math.exp(-_winProbSlope * eval.cp));
}
