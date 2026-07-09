/// Position analysis models - Flutter port of Python's core/models.py
/// Provides data structures for positions, games, and analysis results
library;

import '../utils/fen_utils.dart';

class PositionStats {
  final String fen;
  int games;
  int wins;
  int losses;
  int draws;
  final List<String> gameUrls;

  /// Engine evaluation in centipawns (white's perspective). Null = not yet evaluated.
  int? evalCp;
  int? evalMate;
  int? evalDepth;

  PositionStats({
    required this.fen,
    this.games = 0,
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
    this.evalCp,
    this.evalMate,
    this.evalDepth,
    List<String>? gameUrls,
  }) : gameUrls = gameUrls ?? [];

  bool get hasEval => evalCp != null;

  /// Calculate win rate (0.0 to 1.0)
  double get winRate {
    if (games == 0) return 0.0;
    return (wins + 0.5 * draws) / games;
  }

  /// Win rate as percentage
  double get winRatePercent => winRate * 100;

  /// Human-readable eval display (e.g. "+0.50", "-1.23", "#5").
  String get evalDisplay {
    if (evalMate != null) return '#${evalMate!}';
    if (evalCp == null) return '?';
    final pawns = evalCp! / 100.0;
    final sign = pawns >= 0 ? '+' : '';
    return '$sign${pawns.toStringAsFixed(2)}';
  }

  PositionStats copyWith({
    String? fen,
    int? games,
    int? wins,
    int? losses,
    int? draws,
    List<String>? gameUrls,
  }) {
    return PositionStats(
      fen: fen ?? this.fen,
      games: games ?? this.games,
      wins: wins ?? this.wins,
      losses: losses ?? this.losses,
      draws: draws ?? this.draws,
      evalCp: evalCp,
      evalMate: evalMate,
      evalDepth: evalDepth,
      gameUrls: gameUrls ?? this.gameUrls,
    );
  }

  /// Serialize to JSON
  Map<String, dynamic> toJson() {
    return {
      'fen': fen,
      'games': games,
      'wins': wins,
      'losses': losses,
      'draws': draws,
      'gameUrls': gameUrls,
    };
  }

  /// Deserialize from JSON
  factory PositionStats.fromJson(Map<String, dynamic> json) {
    return PositionStats(
      fen: json['fen'] as String,
      games: json['games'] as int? ?? 0,
      wins: json['wins'] as int? ?? 0,
      losses: json['losses'] as int? ?? 0,
      draws: json['draws'] as int? ?? 0,
      gameUrls: (json['gameUrls'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }
}

class GameInfo {
  final String? pgnText;
  final String white;
  final String black;
  final String result;
  final String date;
  final String site;
  final String event;
  final String whiteElo;
  final String blackElo;

  GameInfo({
    this.pgnText,
    this.white = '',
    this.black = '',
    this.result = '',
    this.date = '',
    this.site = '',
    this.event = '',
    this.whiteElo = '',
    this.blackElo = '',
  });

  /// Human-readable game title
  String get title {
    if (white.isNotEmpty && black.isNotEmpty) {
      return '$white vs $black';
    } else if (event.isNotEmpty) {
      return event;
    } else if (site.isNotEmpty) {
      return site;
    }
    return 'Unknown Game';
  }

  /// Elo rating string, e.g. "1500 vs 1600" or empty.
  String get eloDisplay {
    if (whiteElo.isNotEmpty && blackElo.isNotEmpty) {
      return '$whiteElo vs $blackElo';
    }
    if (whiteElo.isNotEmpty) return 'W: $whiteElo';
    if (blackElo.isNotEmpty) return 'B: $blackElo';
    return '';
  }

  /// Secondary information about the game
  String get subtitle {
    final parts = <String>[];
    if (date.isNotEmpty) parts.add(date);
    if (result.isNotEmpty) parts.add(result);
    return parts.join(' • ');
  }

  /// Parse game info from PGN text
  factory GameInfo.fromPgn(String pgnText) {
    String white = '';
    String black = '';
    String result = '';
    String date = '';
    String site = '';
    String event = '';
    String whiteElo = '';
    String blackElo = '';

    final lines = pgnText.split('\n');
    for (final line in lines) {
      if (line.startsWith('[White "')) {
        white = _extractHeader(line);
      } else if (line.startsWith('[Black "')) {
        black = _extractHeader(line);
      } else if (line.startsWith('[Result "')) {
        result = _extractHeader(line);
      } else if (line.startsWith('[Date "')) {
        date = _extractHeader(line);
      } else if (line.startsWith('[Site "')) {
        site = _extractHeader(line);
      } else if (line.startsWith('[Event "')) {
        event = _extractHeader(line);
      } else if (line.startsWith('[WhiteElo "')) {
        whiteElo = _extractHeader(line);
      } else if (line.startsWith('[BlackElo "')) {
        blackElo = _extractHeader(line);
      }
    }

    return GameInfo(
      pgnText: pgnText,
      white: white,
      black: black,
      result: result,
      date: date,
      site: site,
      event: event,
      whiteElo: whiteElo,
      blackElo: blackElo,
    );
  }

  static String _extractHeader(String line) {
    final start = line.indexOf('"') + 1;
    final end = line.lastIndexOf('"');
    if (start > 0 && end > start) {
      return line.substring(start, end);
    }
    return '';
  }
}

class PositionAnalysis {
  final Map<String, PositionStats> positionStats;
  final List<GameInfo> games;
  final Map<String, List<int>> fenToGameIndices;

  PositionAnalysis({
    Map<String, PositionStats>? positionStats,
    List<GameInfo>? games,
    Map<String, List<int>>? fenToGameIndices,
  })  : positionStats = positionStats ?? {},
        games = games ?? [],
        fenToGameIndices = fenToGameIndices ?? {};

  /// Add or update position statistics
  void addPositionStats(PositionStats stats) {
    positionStats[stats.fen] = stats;
  }

  /// Add a game and return its index
  int addGame(GameInfo game) {
    final index = games.length;
    games.add(game);
    return index;
  }

  /// Create a mapping from FEN to game.
  ///
  /// Games are linked in ascending index order, so checking the last entry is
  /// enough to avoid duplicates — a `contains` scan here is quadratic on
  /// positions that occur in every game (e.g. the starting position).
  void linkFenToGame(String fen, int gameIndex) {
    final list = fenToGameIndices[fen] ??= [];
    if (list.isEmpty || list.last != gameIndex) {
      list.add(gameIndex);
    }
  }

  /// Get all games containing a specific position.
  ///
  /// Normalises the FEN to 4 fields (board/active/castling/en-passant) so
  /// lookups succeed regardless of whether half-move and full-move counters
  /// are present.
  List<GameInfo> getGamesForFen(String fen) {
    final indices = fenToGameIndices[normalizeFen(fen)] ?? [];
    return indices.where((i) => i < games.length).map((i) => games[i]).toList();
  }

  /// Get positions sorted by various criteria.
  ///
  /// `eval_bad_white` — worst eval for White first (most negative evalCp).
  /// `eval_bad_black` — worst eval for Black first (most positive evalCp).
  /// Both `eval_bad_*` sorts only include positions that have engine eval.
  List<PositionStats> getSortedPositions({
    int minGames = 3,
    String sortBy = 'win_rate',
  }) {
    var filtered =
        positionStats.values.where((stats) => stats.games >= minGames).toList();

    if (sortBy == 'eval_bad_white') {
      filtered = filtered.where((s) => s.hasEval).toList();
      filtered.sort((a, b) => (a.evalCp ?? 0).compareTo(b.evalCp ?? 0));
    } else if (sortBy == 'eval_bad_black') {
      filtered = filtered.where((s) => s.hasEval).toList();
      filtered.sort((a, b) => (b.evalCp ?? 0).compareTo(a.evalCp ?? 0));
    } else if (sortBy == 'win_rate') {
      filtered.sort((a, b) => a.winRate.compareTo(b.winRate));
    } else if (sortBy == 'win_rate_desc') {
      filtered.sort((a, b) => b.winRate.compareTo(a.winRate));
    } else if (sortBy == 'games') {
      filtered.sort((a, b) => b.games.compareTo(a.games));
    } else if (sortBy == 'losses') {
      filtered.sort((a, b) => b.losses.compareTo(a.losses));
    }

    return filtered;
  }
}
