/// Difficulty formula constants and helpers shared across the analysis pipeline.
///
/// Used by [AnalysisService] (per-move difficulty) and [UnifiedEnginePane]
/// (overall position difficulty).
library;

import 'dart:math' as math;

// ── Ease formula constants ────────────────────────────────────────────────

const double kEaseAlpha = 1 / 3;
const double kEaseBeta = 1.5;

/// Display multiplier so the 0–1 difficulty value maps to a 0–5 scale.
const double kEaseDisplayScale = 5.0;

/// Convert a centipawn score to a Q value in the range [-1, 1].
///
/// Maps large scores (mate) to +/-1 and uses a logistic curve for normal
/// centipawn values.
double scoreToQ(int cp) {
  if (cp.abs() > 9000) return cp > 0 ? 1.0 : -1.0;
  final winProb = 1.0 / (1.0 + math.exp(-0.004 * cp));
  return 2.0 * winProb - 1.0;
}

/// Win probability sigmoid used by ECA move selection.
///
/// Maps centipawns to [0, 1] using the same constant as the C tree builder's
/// `win_probability()` (0.00368208).  Mate scores saturate to 0.0 / 1.0.
double winProbability(int cp) {
  if (cp.abs() > 9000) return cp > 0 ? 1.0 : 0.0;
  return 1.0 / (1.0 + math.exp(-0.00368208 * cp));
}
