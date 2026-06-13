/// Difficulty formula constants and helpers shared across the analysis pipeline.
///
/// Used by [AnalysisService] (per-move difficulty) and [UnifiedEnginePane]
/// (overall position difficulty).
library;

import 'dart:math' as math;

import 'eval_constants.dart';

// ── Ease formula constants ────────────────────────────────────────────────

const double kEaseAlpha = 1 / 3;
const double kEaseBeta = 1.5;

/// Convert a centipawn score to a Q value in the range [-1, 1].
///
/// Maps large scores (mate) to +/-1 and uses a logistic curve for normal
/// centipawn values. Uses [kWinProbK] for consistency with [winProbability].
double scoreToQ(int cp) {
  if (cp.abs() > kMateSaturationCp) return cp > 0 ? 1.0 : -1.0;
  final winProb = 1.0 / (1.0 + math.exp(-kWinProbK * cp));
  return 2.0 * winProb - 1.0;
}

/// Win probability sigmoid used by expectimax value propagation.
///
/// Maps centipawns to [0, 1] using [kWinProbK] which matches the C tree
/// builder's `win_probability()`.  Mate scores saturate to 0.0 / 1.0.
double winProbability(int cp) {
  if (cp.abs() > kMateSaturationCp) return cp > 0 ? 1.0 : 0.0;
  return 1.0 / (1.0 + math.exp(-kWinProbK * cp));
}

/// Inverse of [winProbability]: converts a win probability V in (0,1) back
/// to an approximate centipawn value.
int expectedCpFromWinProb(double v) {
  if (v <= 0.01) return -9999;
  if (v >= 0.99) return 9999;
  return (-math.log((1.0 / v) - 1.0) / kWinProbK).round();
}
