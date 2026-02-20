/// Unified model for Lichess Explorer API responses.
///
/// Used across the entire move-generation pipeline: [ProbabilityService],
/// [RepertoireGenerationService], [MoveAnalysisPool], and the DB-only
/// generation isolate.  Centralises parsing so there is exactly one
/// JSON → Dart conversion for Explorer data.
library;

class ExplorerMove {
  final String san;
  final String uci;
  final int white;
  final int draws;
  final int black;

  /// Percentage of games at this position that played this move (0–100).
  final double playRate;

  const ExplorerMove({
    required this.san,
    required this.uci,
    required this.white,
    required this.draws,
    required this.black,
    required this.playRate,
  });

  int get total => white + draws + black;

  /// Play rate as a fraction in [0, 1] for probability calculations.
  double get playFraction => playRate / 100.0;

  /// Win rate from the given side's perspective: (wins + ½·draws) / total.
  double winRateFor({required bool asWhite}) {
    if (total <= 0) return 0.5;
    final wins = asWhite ? white : black;
    return (wins + 0.5 * draws) / total;
  }

  String get formattedPlayRate => '${playRate.toStringAsFixed(1)}%';

  String toPgnComment() =>
      '{Move probability: ${playRate.toStringAsFixed(1)}%}';
}

class ExplorerResponse {
  final String fen;
  final List<ExplorerMove> moves;
  final int totalGames;

  const ExplorerResponse({
    required this.fen,
    required this.moves,
    required this.totalGames,
  });

  /// Parse a raw JSON map returned by the Lichess Explorer endpoint.
  factory ExplorerResponse.fromJson(
    Map<String, dynamic> data, {
    required String fen,
  }) {
    int totalGames = 0;
    for (final move in data['moves'] as List? ?? []) {
      final w = move['white'] as int? ?? 0;
      final d = move['draws'] as int? ?? 0;
      final b = move['black'] as int? ?? 0;
      totalGames += w + d + b;
    }

    final moves = <ExplorerMove>[];
    for (final move in data['moves'] as List? ?? []) {
      final w = move['white'] as int? ?? 0;
      final d = move['draws'] as int? ?? 0;
      final b = move['black'] as int? ?? 0;
      final moveTotal = w + d + b;
      final playRate =
          totalGames > 0 ? (moveTotal / totalGames) * 100 : 0.0;

      moves.add(ExplorerMove(
        san: move['san'] as String? ?? '',
        uci: move['uci'] as String? ?? '',
        white: w,
        draws: d,
        black: b,
        playRate: playRate,
      ));
    }

    moves.sort((a, b) => b.playRate.compareTo(a.playRate));
    return ExplorerResponse(fen: fen, moves: moves, totalGames: totalGames);
  }

  /// Find the best move for [asWhite]'s side by win rate, breaking ties
  /// by play rate.  Only considers moves with play rate ≥ [minPlayRate].
  ///
  /// Returns `null` if no viable move exists.
  ExplorerMove? bestMoveForSide({
    required bool asWhite,
    double minPlayRate = 1.0,
  }) {
    final viable = moves
        .where((m) => m.uci.isNotEmpty && m.playRate >= minPlayRate)
        .toList();
    if (viable.isEmpty) return null;
    return viable.reduce((a, b) {
      final aWr = a.winRateFor(asWhite: asWhite);
      final bWr = b.winRateFor(asWhite: asWhite);
      if (aWr != bWr) return aWr > bWr ? a : b;
      return a.playRate > b.playRate ? a : b;
    });
  }
}
