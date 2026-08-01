/// Per-game review summary derived from stored `[%eval]` annotations.
///
/// The games list wants a one-glance answer to "how messy was this game for
/// *me*?" without running an engine: if the game's PGN already carries eval
/// comments (from the viewer's analysis pass, the background auto-analysis
/// job, or a Lichess download with server evals), the same winning-chance
/// classification the Analysis tab uses can be replayed from them. Pure and
/// top-level so batches can run through `compute`.
library;

import '../../../services/game_analysis_controller.dart';

/// Mistake counts for one player's moves in one analyzed game.
class GameReviewSummary {
  const GameReviewSummary({
    required this.blunders,
    required this.mistakes,
    required this.inaccuracies,
  });

  final int blunders;
  final int mistakes;
  final int inaccuracies;

  bool get clean => blunders == 0 && mistakes == 0 && inaccuracies == 0;

  /// Tooltip text for the counts cell. The cell itself shows the three numbers
  /// (see `MistakeCounts`) — it used to show only the worst category, which
  /// named one number and silently dropped the other two.
  String get breakdown {
    if (clean) return 'Analyzed: no blunders, mistakes or inaccuracies. 🎉';
    return 'Analyzed: ${_counted(blunders, 'blunder')}, '
        '${_counted(mistakes, 'mistake')}, '
        '${_counted(inaccuracies, 'inaccuracy')}.';
  }

  static String _counted(int n, String word) {
    if (n == 1) return '1 $word';
    final plural = word == 'inaccuracy' ? 'inaccuracies' : '${word}s';
    return '$n $plural';
  }
}

/// Count one side's classified mistakes from already-parsed evals (used
/// directly by the auto-analysis job, which has the evals in memory).
GameReviewSummary summaryFromEvals(
  List<MoveEval> evals, {
  required bool meWhite,
}) {
  var blunders = 0, mistakes = 0, inaccuracies = 0;
  for (final e in evals) {
    if (e.isWhiteMove != meWhite) continue;
    switch (e.classification) {
      case MoveClassification.blunder:
        blunders++;
      case MoveClassification.mistake:
        mistakes++;
      case MoveClassification.inaccuracy:
        inaccuracies++;
      case MoveClassification.interesting:
      case MoveClassification.normal:
        break;
    }
  }
  return GameReviewSummary(
    blunders: blunders,
    mistakes: mistakes,
    inaccuracies: inaccuracies,
  );
}

/// Summarize one game's stored evals for the player on [meWhite]'s side.
///
/// Returns null when the side is unknown or the game does not count as
/// analyzed (see [parseCachedEvals] — at most 2 plies may lack an eval).
GameReviewSummary? summarizeGameReview(String pgn, {required bool? meWhite}) {
  if (meWhite == null) return null;
  ({List<MoveEval> evals, double startWinChance, int totalMoves})? parsed;
  try {
    parsed = parseCachedEvals(pgn);
  } catch (_) {
    return null; // malformed PGN — treat as unanalyzed
  }
  if (parsed == null) return null;
  return summaryFromEvals(parsed.evals, meWhite: meWhite);
}

/// Batch form for `compute`: one summary (or null) per (pgn, meWhite) pair.
List<GameReviewSummary?> computeReviewSummariesBatch(
  List<(String, bool?)> games,
) => [
  for (final (pgn, meWhite) in games)
    summarizeGameReview(pgn, meWhite: meWhite),
];
