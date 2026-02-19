/// A position where the engine says the player should be at a disadvantage
/// but their actual game results are relatively good.
library;

class EngineWeaknessResult {
  final String fen;

  /// Engine evaluation in centipawns from white's perspective.
  final int evalCp;

  /// Mate score from white's perspective (if applicable).
  final int? evalMate;

  final int depth;
  final int gamesPlayed;
  final int wins;
  final int losses;
  final int draws;
  final double winRate;

  /// Move sequence to reach this position (e.g. "1.e4 e5 2.Nf3").
  final String movePath;

  /// Whether the player was White in the games that reached this position.
  final bool playerIsWhite;

  const EngineWeaknessResult({
    required this.fen,
    required this.evalCp,
    this.evalMate,
    required this.depth,
    required this.gamesPlayed,
    required this.wins,
    required this.losses,
    required this.draws,
    required this.winRate,
    required this.movePath,
    required this.playerIsWhite,
  });

  /// Human-readable eval (e.g. "+0.50", "-1.23", "#5").
  String get evalDisplay {
    if (evalMate != null) return '#${evalMate!}';
    final pawns = evalCp / 100.0;
    final sign = pawns >= 0 ? '+' : '';
    return '$sign${pawns.toStringAsFixed(2)}';
  }

  Map<String, dynamic> toJson() => {
        'fen': fen,
        'evalCp': evalCp,
        if (evalMate != null) 'evalMate': evalMate,
        'depth': depth,
        'gamesPlayed': gamesPlayed,
        'wins': wins,
        'losses': losses,
        'draws': draws,
        'winRate': winRate,
        'movePath': movePath,
        'playerIsWhite': playerIsWhite,
      };

  factory EngineWeaknessResult.fromJson(Map<String, dynamic> j) =>
      EngineWeaknessResult(
        fen: j['fen'] as String,
        evalCp: j['evalCp'] as int,
        evalMate: j['evalMate'] as int?,
        depth: j['depth'] as int,
        gamesPlayed: j['gamesPlayed'] as int,
        wins: j['wins'] as int,
        losses: j['losses'] as int,
        draws: j['draws'] as int,
        winRate: (j['winRate'] as num).toDouble(),
        movePath: j['movePath'] as String,
        playerIsWhite: j['playerIsWhite'] as bool,
      );
}
