/// Unified model for Lichess Explorer API responses.
///
/// Used across the move-generation pipeline: [ProbabilityService],
/// [TreeBuildService], and [MoveAnalysisPool].  Centralises parsing so
/// there is exactly one JSON → Dart conversion for Explorer data.
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

/// Where an explorer answer came from, which is also where one of its games
/// can be fetched from.
enum ExplorerGameSource {
  /// The Lichess player database: `lichess.org/game/export/<id>`.
  lichess,

  /// The Lichess masters database: `explorer.lichess.ovh/masters/pgn/<id>`.
  masters,

  /// The local TWIC database: `MasterGamesDb.game(<id>)`.
  twic,
}

/// One game the explorer names for a position — lila's "top games" list.
class ExplorerGame {
  const ExplorerGame({
    required this.id,
    required this.source,
    required this.white,
    required this.black,
    required this.whiteElo,
    required this.blackElo,
    required this.result,
    required this.year,
    this.month,
    this.event = '',
    this.san = '',
  });

  /// Lichess game id, or the local database's integer id as text.
  final String id;
  final ExplorerGameSource source;

  final String white;
  final String black;
  final int? whiteElo;
  final int? blackElo;

  /// `1-0`, `0-1`, `1/2-1/2` or `*`.
  final String result;

  final int? year;
  final int? month;

  /// The event, when the source knows it (TWIC); empty for Lichess games.
  final String event;

  /// The move this game played from the position, in SAN, when known.
  final String san;

  /// The higher rating of the two, for a one-glance strength.
  int get topElo {
    final w = whiteElo ?? 0;
    final b = blackElo ?? 0;
    return w > b ? w : b;
  }

  /// "2024" or "2024-03", for a compact date column.
  String get when {
    final y = year;
    if (y == null) return '';
    final m = month;
    return m == null ? '$y' : '$y-${m.toString().padLeft(2, '0')}';
  }

  /// Parse one entry of the API's `topGames` / `recentGames` arrays.
  factory ExplorerGame.fromJson(
    Map<String, dynamic> json, {
    required ExplorerGameSource source,
    required String san,
  }) {
    final white = json['white'] as Map<String, dynamic>? ?? const {};
    final black = json['black'] as Map<String, dynamic>? ?? const {};
    final winner = json['winner'] as String?;
    return ExplorerGame(
      id: json['id'] as String? ?? '',
      source: source,
      white: white['name'] as String? ?? '?',
      black: black['name'] as String? ?? '?',
      whiteElo: white['rating'] as int?,
      blackElo: black['rating'] as int?,
      result: switch (winner) {
        'white' => '1-0',
        'black' => '0-1',
        null => json.containsKey('winner') ? '1/2-1/2' : '*',
        _ => '*',
      },
      year: json['year'] as int?,
      month: json['month'] is String
          ? int.tryParse((json['month'] as String).split('-').last)
          : json['month'] as int?,
      san: san,
    );
  }
}

class ExplorerResponse {
  final String fen;
  final List<ExplorerMove> moves;
  final int totalGames;

  /// Games the source names for this position, strongest first — the ones
  /// worth opening.  Empty when the caller did not ask for any.
  final List<ExplorerGame> topGames;

  /// The most recent games, when the source lists them separately (the
  /// Lichess player database does; masters and TWIC fold them into
  /// [topGames]).
  final List<ExplorerGame> recentGames;

  /// Opening name/ECO for this position, when the API identifies one
  /// (e.g. "Sicilian Defense" / "B20"). Null for unnamed positions.
  final String? openingName;
  final String? openingEco;

  /// Result split over every game at this position, as reported by the
  /// API's top-level `white`/`draws`/`black` fields. Null when the caller
  /// built the response without them; see [whiteTotal] for the fallback.
  final int? white;
  final int? draws;
  final int? black;

  const ExplorerResponse({
    required this.fen,
    required this.moves,
    required this.totalGames,
    this.openingName,
    this.openingEco,
    this.white,
    this.draws,
    this.black,
    this.topGames = const [],
    this.recentGames = const [],
  });

  /// Result totals for the position — the explorer's Σ row. Falls back to
  /// summing [moves] when the API-level counts were not supplied.
  int get whiteTotal => white ?? moves.fold(0, (n, m) => n + m.white);
  int get drawTotal => draws ?? moves.fold(0, (n, m) => n + m.draws);
  int get blackTotal => black ?? moves.fold(0, (n, m) => n + m.black);

  /// Parse a raw JSON map returned by the Lichess Explorer endpoint.
  ///
  /// [gameSource] says which database answered, so the games it lists can be
  /// fetched from the right place; the top-level `topGames` / `recentGames`
  /// arrays are parsed when it is given.
  factory ExplorerResponse.fromJson(
    Map<String, dynamic> data, {
    required String fen,
    ExplorerGameSource? gameSource,
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
      final playRate = totalGames > 0 ? (moveTotal / totalGames) * 100 : 0.0;

      moves.add(
        ExplorerMove(
          san: move['san'] as String? ?? '',
          uci: move['uci'] as String? ?? '',
          white: w,
          draws: d,
          black: b,
          playRate: playRate,
        ),
      );
    }

    moves.sort((a, b) => b.playRate.compareTo(a.playRate));
    final opening = data['opening'] as Map<String, dynamic>?;

    // The API names each game's move by UCI; the row's SAN is what a reader
    // wants beside it.
    final sanByUci = {for (final m in moves) m.uci: m.san};
    List<ExplorerGame> games(String key) => gameSource == null
        ? const []
        : [
            for (final g in data[key] as List? ?? const [])
              if (g is Map<String, dynamic>)
                ExplorerGame.fromJson(
                  g,
                  source: gameSource,
                  san: sanByUci[g['uci'] as String? ?? ''] ?? '',
                ),
          ];

    return ExplorerResponse(
      fen: fen,
      moves: moves,
      totalGames: totalGames,
      openingName: opening?['name'] as String?,
      openingEco: opening?['eco'] as String?,
      white: data['white'] as int?,
      draws: data['draws'] as int?,
      black: data['black'] as int?,
      topGames: games('topGames'),
      recentGames: games('recentGames'),
    );
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
