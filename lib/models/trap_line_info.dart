/// Trap line info — mirrors the C `TrapLineInfo` struct.
///
/// Represents a position where the opponent's most popular move is
/// significantly worse than the objectively best move, meaning they are
/// likely to blunder into a worse position.
library;

class TrapLineInfo {
  /// SAN moves from root to the trap position.
  final List<String> movesSan;

  /// Composite trap score [0, 1]: clamp(eval_diff/200, 0, 1) * popular_prob.
  final double trapScore;

  /// Probability opponent plays the bad (popular) move.
  final double popularProb;

  /// SAN of the most popular (bad) move.
  final String popularMove;

  /// SAN of the objectively best move.
  final String bestMove;

  /// Eval after popular move from our perspective (centipawns).
  final int popularEvalCp;

  /// Eval after best move from our perspective (centipawns).
  final int bestEvalCp;

  /// Centipawn gain: popularEvalCp - bestEvalCp (positive = we gain).
  final int evalDiffCp;

  /// Probability of reaching this position (cumulative).
  final double cumulativeProb;

  /// How much better we do in practice (expectimax) than raw eval predicts.
  /// V - wp(eval_for_us). Positive = subtree is trickier than eval suggests.
  final double trickSurplus;

  /// Raw expectimax value V at this node.
  final double expectimaxValue;

  /// wp(eval_for_us) at this node.
  final double wpEval;

  const TrapLineInfo({
    required this.movesSan,
    required this.trapScore,
    required this.popularProb,
    required this.popularMove,
    required this.bestMove,
    required this.popularEvalCp,
    required this.bestEvalCp,
    required this.evalDiffCp,
    required this.cumulativeProb,
    required this.trickSurplus,
    required this.expectimaxValue,
    required this.wpEval,
  });

  Map<String, dynamic> toJson() => {
        'moves_san': movesSan,
        'trap_score': trapScore,
        'popular_prob': popularProb,
        'popular_move': popularMove,
        'best_move': bestMove,
        'popular_eval_cp': popularEvalCp,
        'best_eval_cp': bestEvalCp,
        'eval_diff_cp': evalDiffCp,
        'cumulative_prob': cumulativeProb,
        'trick_surplus': trickSurplus,
        'expectimax_value': expectimaxValue,
        'wp_eval': wpEval,
      };

  factory TrapLineInfo.fromJson(Map<String, dynamic> json) => TrapLineInfo(
        movesSan: (json['moves_san'] as List).cast<String>(),
        trapScore: (json['trap_score'] as num).toDouble(),
        popularProb: (json['popular_prob'] as num).toDouble(),
        popularMove: json['popular_move'] as String,
        bestMove: json['best_move'] as String,
        popularEvalCp: json['popular_eval_cp'] as int,
        bestEvalCp: json['best_eval_cp'] as int,
        evalDiffCp: json['eval_diff_cp'] as int,
        cumulativeProb: (json['cumulative_prob'] as num).toDouble(),
        trickSurplus: (json['trick_surplus'] as num).toDouble(),
        expectimaxValue: (json['expectimax_value'] as num).toDouble(),
        wpEval: (json['wp_eval'] as num).toDouble(),
      );

  /// Format eval in pawn units (e.g. +1.25, -0.50).
  String formatEval(int cp) {
    final pawns = cp / 100.0;
    return '${pawns >= 0 ? "+" : ""}${pawns.toStringAsFixed(2)}';
  }

  /// Human-readable summary matching the C output format.
  String get summary {
    final surplus = '${trickSurplus >= 0 ? "+" : ""}${(trickSurplus * 100).toStringAsFixed(1)}%';
    return 'Trick surplus $surplus (V=${(expectimaxValue * 100).toStringAsFixed(1)}% '
        'wp=${(wpEval * 100).toStringAsFixed(1)}%) | '
        'Trap ${(trapScore * 100).toStringAsFixed(0)}% | '
        'Reach ${(cumulativeProb * 100).toStringAsFixed(3)}%';
  }

  /// One-line description of what the opponent does wrong.
  String get mistakeDescription {
    return '$popularMove (${(popularProb * 100).toStringAsFixed(0)}%) '
        'loses ${evalDiffCp}cp vs best $bestMove';
  }

  /// The move sequence formatted as PGN-style text.
  String get movesText {
    final buf = StringBuffer();
    for (int i = 0; i < movesSan.length; i++) {
      if (i % 2 == 0) buf.write('${(i ~/ 2) + 1}.');
      buf.write('${movesSan[i]} ');
    }
    return buf.toString().trimRight();
  }
}
