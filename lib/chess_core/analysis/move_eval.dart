/// One move's engine verdict, and the Lichess-style winning-chance model
/// that turns a series of them into `?!` / `?` / `??` marks.
///
/// Move classification thresholds (winning-chance swing, White-normalized):
/// - Blunder (??): >= 0.30
/// - Mistake (?):  >= 0.20
/// - Inaccuracy (?!): >= 0.10
///
/// Every reader and writer of an analyzed game — the live pass, the cached
/// `[%eval]` restore and the movetext's own marker pass — measures the first
/// move against [initialWinChance], so a stored game reads the same
/// everywhere.
library;

import 'package:chess_auto_prep/utils/chess_utils.dart' show formatEvalDisplay;
import 'package:chess_auto_prep/utils/ease_utils.dart' show winningChanceFromCp;
import 'package:chess_auto_prep/utils/eval_constants.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart'
    show formatEvalCommentValue;

/// Eval at a single ply (after the move is played).
class MoveEval {
  /// 1-based mainline index, including null moves.
  final int ply;
  final String san;
  final String fenBefore;
  final String fenAfter;

  /// White-normalized centipawns.
  final int? scoreCp;

  /// White-normalized mate-in-N.
  final int? scoreMate;

  /// White's winning chance in [-1, 1].
  final double winningChance;
  final MoveClassification classification;

  /// Maia's predicted probability of this move (0-1).
  final double? maiaProb;

  /// Most likely move according to Maia (SAN), and its probability.
  final String? maiaTopMove;
  final double? maiaTopProb;

  /// Engine's preferred continuation from the position before the move (SAN).
  final List<String> bestLine;

  /// Analysis depth.
  final int? depth;

  /// This move checkmated the opponent. The eval is not an engine score
  /// (there is no position left to search — mate-0 sign is ambiguous), so
  /// [scoreCp]/[scoreMate] stay null and [winningChance] is exactly ±1.
  final bool deliversCheckmate;

  const MoveEval({
    required this.ply,
    required this.san,
    required this.fenBefore,
    required this.fenAfter,
    this.scoreCp,
    this.scoreMate,
    required this.winningChance,
    this.classification = MoveClassification.normal,
    this.maiaProb,
    this.maiaTopMove,
    this.maiaTopProb,
    this.bestLine = const [],
    this.depth,
    this.deliversCheckmate = false,
  });

  bool get isWhiteMove => isWhiteToMove(fenBefore);

  /// A move worth a card or an inline mark that has no engine line to offer
  /// with it — the `[%pv]` was never stored (a review pass from before lines
  /// were kept, or a score served from the eval cache, which keeps none).
  bool get needsBestLine =>
      classification != MoveClassification.normal &&
      !deliversCheckmate &&
      bestLine.isEmpty;

  MoveEval copyWith({
    MoveClassification? classification,
    List<String>? bestLine,
  }) => MoveEval(
    ply: ply,
    san: san,
    fenBefore: fenBefore,
    fenAfter: fenAfter,
    scoreCp: scoreCp,
    scoreMate: scoreMate,
    winningChance: winningChance,
    classification: classification ?? this.classification,
    maiaProb: maiaProb,
    maiaTopMove: maiaTopMove,
    maiaTopProb: maiaTopProb,
    bestLine: bestLine ?? this.bestLine,
    depth: depth,
    deliversCheckmate: deliversCheckmate,
  );

  int get effectiveCp {
    if (deliversCheckmate) {
      return winningChance >= 0 ? kMateCpBase : -kMateCpBase;
    }
    return effectiveCpFromScores(scoreCp: scoreCp, scoreMate: scoreMate);
  }

  /// Human-readable score for a tooltip or a move row: `+1.3`, `-0.5`, `#3`.
  ///
  /// A mating move gets a bare `#`. It carries no engine score — there is no
  /// position left to search — so the plain formatter would render the move
  /// that won the game as `--`, which is what the chart's tooltip used to do
  /// while the move list beside it said `#`.
  String get evalDisplay => deliversCheckmate
      ? '#'
      : formatEvalDisplay(scoreCp: scoreCp, scoreMate: scoreMate);

  /// Format as a Lichess-compatible `[%eval]` comment value, with optional
  /// depth suffix (e.g. `1.23,18` or `#3,20`).
  String toEvalComment() => formatEvalCommentValue(
    scoreCp: scoreCp,
    scoreMate: scoreMate,
    depth: depth,
  );
}

enum MoveClassification {
  normal,
  interesting,
  inaccuracy,
  mistake,
  blunder;

  /// Standard PGN move-quality glyph, shared by display and saved analysis.
  int? get nag => switch (this) {
    normal => null,
    interesting => 5,
    inaccuracy => 6,
    mistake => 2,
    blunder => 4,
  };

  /// Fill an absent verdict without duplicating or replacing an annotator's
  /// own move-quality glyph. Positional NAGs remain alongside the verdict.
  List<int>? annotateNags(List<int>? existing) {
    final id = nag;
    if (id == null ||
        (existing ?? const <int>[]).any((n) => n >= 1 && n <= 6)) {
      return existing;
    }
    return [id, ...?existing];
  }
}

// ---------------------------------------------------------------------------
// Winning-chance model (Lichess logistic)
// ---------------------------------------------------------------------------

/// Lichess-style centipawn-to-winning-chance conversion.
///
/// Maps mate scores to pseudo-CP, then delegates to the shared
/// [winningChanceFromCp] curve (the same `kWinProbK` logistic used by the
/// ease/expectimax pipeline). See [winningChanceFromCp] for why the input is
/// clamped to ±1000 cp here rather than saturated at mate scores.
double cpToWinningChance(int? cp, int? mate) =>
    winningChanceFromCp(effectiveCpFromScores(scoreCp: cp, scoreMate: mate));

/// Winning chance the first move's swing is measured against.
///
/// An even game. Nothing writes the engine's score for a game's *starting*
/// position to disk — a review pass persists movetext, and `[%eval]` lives on
/// moves — so no reader can recover one. Every path that classifies moves must
/// therefore start its chain here, or the same game reads differently
/// depending on who is looking: the live pass, `parseCachedEvals`, and the
/// movetext's own marker pass all begin from this value.
double initialWinChance() => cpToWinningChance(0, null);

/// The winning chance the side that played a move gave away: how far
/// [after] fell from [before] for the mover, clamped to `[0, 1]` so a gain
/// never counts against them.
double winningChanceLoss({
  required bool isWhiteMove,
  required double before,
  required double after,
}) => (isWhiteMove ? before - after : after - before).clamp(0.0, 1.0);

/// Classify by winning-chance loss, then mark rare sound Maia moves interesting.
MoveClassification classifyMove(double delta, {double? maiaProb}) {
  if (delta >= 0.30) return MoveClassification.blunder;
  if (delta >= 0.20) return MoveClassification.mistake;
  if (delta >= 0.10) return MoveClassification.inaccuracy;
  if (maiaProb != null && maiaProb < 0.05) {
    return MoveClassification.interesting;
  }
  return MoveClassification.normal;
}
