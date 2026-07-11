/// Centralized constants for chess evaluation encoding.
///
/// All eval-related code should use these constants instead of bare numeric
/// literals. The sigmoid constant [kWinProbK] matches the Lichess / lila
/// model and the C tree builder's `win_probability()`.
library;

/// Pseudo-centipawn base for converting mate-in-N to a sortable integer.
///
/// `mate > 0` → `kMateCpBase - mate` (winning, large positive).
/// `mate < 0` → `-(kMateCpBase - mate.abs())` (losing, large negative).
const int kMateCpBase = 10000;

/// Centipawn threshold beyond which a score is treated as forced mate
/// for display purposes (`#` or `-#`).
const int kMateCpThreshold = kMateCpBase;

/// Centipawn value beyond which sigmoid functions saturate to 0/1.
/// Prevents exp() overflow on extreme scores.
const int kMateSaturationCp = 9000;

/// Logistic sigmoid constant for centipawn → win-probability conversion.
///
/// Matches the Lichess / lila UI model:
/// `2 / (1 + exp(-kWinProbK * cp)) - 1`
///
/// Source: <https://github.com/lichess-org/scalachess/blob/master/core/src/main/scala/eval.scala>
/// Also matches the C tree builder's `win_probability()` (0.00368208).
const double kWinProbK = 0.00368208;

/// Sentinel for "worst possible eval" when searching for a maximum.
/// Use instead of bare `-100000`.
const int kWorstEvalCp = -100000;

/// Sentinel for "best possible eval" when searching for a minimum.
/// Use instead of bare `100000`.
const int kBestEvalCp = 100000;

/// Convert a mate-in-N score to a pseudo-centipawn value.
///
/// Positive mate → large positive cp (winning).
/// Negative mate → large negative cp (losing).
/// Returns 0 if [scoreMate] is null.
int mateToCp(int? scoreMate) {
  if (scoreMate == null) return 0;
  return scoreMate > 0
      ? kMateCpBase - scoreMate.abs()
      : -(kMateCpBase - scoreMate.abs());
}

/// Compute an effective centipawn value from optional cp and mate scores.
///
/// Mate scores take precedence. Returns 0 if both are null.
int effectiveCpFromScores({int? scoreCp, int? scoreMate}) {
  if (scoreMate != null) return mateToCp(scoreMate);
  return scoreCp ?? 0;
}

/// Whether [cp] represents a forced-mate eval for display purposes.
bool isMateEval(int cp) => cp.abs() >= kMateCpThreshold;

/// Moves under this probability are noise for probability-weighted
/// aggregates (ease regret, local CPL): they contribute almost nothing to
/// the weighted sum but their evals can be wild, so they are skipped.
const double kNegligibleMoveProb = 0.01;
