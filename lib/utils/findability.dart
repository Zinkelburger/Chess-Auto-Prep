/// Human-findability reference probabilities by rating.
///
/// Ported from FlawChess (`frontend/src/lib/engine/findability.ts`,
/// AGPL-3.0, github.com/flawchess/flawchess): a move whose human play
/// probability clears the rating's reference bar counts as findable; below
/// the bar it is discounted proportionally.  The factor is demote-only —
/// it caps at 1.0, so a findable move is never boosted.
library;

import 'piecewise_linear.dart';

/// (elo, pRef) anchor points, elo ascending.  A 600 needs ~1-in-8 play
/// probability before a move counts as findable; a 2600 finds nearly
/// everything.
const List<(int, double)> kFindabilityAnchors = [
  (600, 0.12),
  (1000, 0.08),
  (1400, 0.05),
  (1800, 0.03),
  (2200, 0.015),
  (2600, 0.005),
];

/// Piecewise-linear interpolation of the findability bar at [elo], clamped
/// to the anchor range.
double pRefForElo(int elo) =>
    interpolatePiecewiseLinear(kFindabilityAnchors, elo);

/// Demote-only findability weight: `min(1, p / pRef)`.
///
/// [humanProb] is the Maia probability of the move; a negative value means
/// "no Maia data" and returns 1.0 (never distort on missing evidence), as
/// does a non-positive [pRef].
double findabilityFactor(double humanProb, double pRef) {
  if (humanProb < 0 || pRef <= 0) return 1.0;
  final factor = humanProb / pRef;
  return factor >= 1.0 ? 1.0 : factor;
}
