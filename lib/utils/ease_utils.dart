/// Ease formula constants and helpers shared across the analysis pipeline.
///
/// Used by [MoveAnalysisPool] (per-move ease) and [UnifiedEnginePane]
/// (overall position ease).
library;

import 'dart:math' as math;

// ── Ease formula constants ────────────────────────────────────────────────

const double kEaseAlpha = 1 / 3;
const double kEaseBeta = 1.5;

/// Convert a centipawn score to a Q value in the range [-1, 1].
///
/// Maps large scores (mate) to +/-1 and uses a logistic curve for normal
/// centipawn values.
double scoreToQ(int cp) {
  if (cp.abs() > 9000) return cp > 0 ? 1.0 : -1.0;
  final winProb = 1.0 / (1.0 + math.exp(-0.004 * cp));
  return 2.0 * winProb - 1.0;
}
