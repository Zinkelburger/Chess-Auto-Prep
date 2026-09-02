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

/// One of my classified mistakes, with enough to draw it and open it: the
/// position it was played in, the move, and what the engine wanted instead
/// when the stored analysis says.
class ReviewMoment {
  const ReviewMoment({
    required this.ply,
    required this.san,
    required this.fenBefore,
    required this.classification,
    this.scoreCp,
    this.scoreMate,
    this.bestSan,
  });

  /// 1-based: 1 = White's first move. Also the mainline index *after* the
  /// move, which is where the viewer lands when the moment is opened.
  final int ply;
  final String san;
  final String fenBefore;
  final MoveClassification classification;

  /// White-normalized eval after the move, as the graph shows it.
  final int? scoreCp;
  final int? scoreMate;

  /// The engine's preferred move in [fenBefore], when a `[%pv]` was stored.
  final String? bestSan;

  bool get isWhiteMove => ply.isOdd;
}

/// Mistake counts for one player's moves in one analyzed game.
class GameReviewSummary {
  const GameReviewSummary({
    required this.blunders,
    required this.mistakes,
    required this.inaccuracies,
    this.moments = const [],
  });

  final int blunders;
  final int mistakes;
  final int inaccuracies;

  /// The counted moves themselves, in game order. Empty when the counts came
  /// from the review store rather than a stored eval series — the store keeps
  /// the tally, not the moves.
  final List<ReviewMoment> moments;

  bool get hasMoments => moments.isNotEmpty;

  /// The same counts, carrying [moments]. Used when a stored tally arrives for
  /// a game whose eval series was already read: the store's verdict wins the
  /// numbers, and the moves stay on the card.
  GameReviewSummary withMoments(List<ReviewMoment> moments) =>
      GameReviewSummary(
        blunders: blunders,
        mistakes: mistakes,
        inaccuracies: inaccuracies,
        moments: moments,
      );

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
  final moments = <ReviewMoment>[];
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
        continue;
    }
    moments.add(
      ReviewMoment(
        ply: e.ply,
        san: e.san,
        fenBefore: e.fenBefore,
        classification: e.classification,
        scoreCp: e.scoreCp,
        scoreMate: e.scoreMate,
        bestSan: e.bestLine.isEmpty ? null : e.bestLine.first,
      ),
    );
  }
  return GameReviewSummary(
    blunders: blunders,
    mistakes: mistakes,
    inaccuracies: inaccuracies,
    moments: moments,
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
