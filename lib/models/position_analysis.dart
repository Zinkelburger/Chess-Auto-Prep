/// Position analysis models - Flutter port of Python's core/models.py
/// Provides data structures for positions, games, and analysis results

class PositionStats {
  final String fen;
  int games;
  int wins;
  int losses;
  int draws;
  final List<String> gameUrls;

  PositionStats({
    required this.fen,
    this.games = 0,
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
    List<String>? gameUrls,
  }) : gameUrls = gameUrls ?? [];

  /// Calculate win rate (0.0 to 1.0)
  double get winRate {
    if (games == 0) return 0.0;
    return (wins + 0.5 * draws) / games;
  }

  /// Win rate as percentage
  double get winRatePercent => winRate * 100;

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

  GameInfo({
    this.pgnText,
    this.white = '',
    this.black = '',
    this.result = '',
    this.date = '',
    this.site = '',
    this.event = '',
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

    // Parse headers from PGN
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

  /// Serialize to JSON
  Map<String, dynamic> toJson() {
    return {
      'pgnText': pgnText,
      'white': white,
      'black': black,
      'result': result,
      'date': date,
      'site': site,
      'event': event,
    };
  }

  /// Deserialize from JSON
  factory GameInfo.fromJson(Map<String, dynamic> json) {
    return GameInfo(
      pgnText: json['pgnText'] as String?,
      white: json['white'] as String? ?? '',
      black: json['black'] as String? ?? '',
      result: json['result'] as String? ?? '',
      date: json['date'] as String? ?? '',
      site: json['site'] as String? ?? '',
      event: json['event'] as String? ?? '',
    );
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

  /// Create a mapping from FEN to game
  void linkFenToGame(String fen, int gameIndex) {
    if (!fenToGameIndices.containsKey(fen)) {
      fenToGameIndices[fen] = [];
    }
    if (!fenToGameIndices[fen]!.contains(gameIndex)) {
      fenToGameIndices[fen]!.add(gameIndex);
    }
  }

  /// Get all games containing a specific position
  List<GameInfo> getGamesForFen(String fen) {
    final indices = fenToGameIndices[fen] ?? [];
    return indices
        .where((i) => i < games.length)
        .map((i) => games[i])
        .toList();
  }

  /// Get positions sorted by various criteria
  List<PositionStats> getSortedPositions({
    int minGames = 3,
    String sortBy = 'win_rate',
  }) {
    var filtered = positionStats.values
        .where((stats) => stats.games >= minGames)
        .toList();

    if (sortBy == 'win_rate') {
      filtered.sort((a, b) => a.winRate.compareTo(b.winRate));
    } else if (sortBy == 'games') {
      filtered.sort((a, b) => b.games.compareTo(a.games));
    } else if (sortBy == 'losses') {
      filtered.sort((a, b) => b.losses.compareTo(a.losses));
    }

    return filtered;
  }

  /// Serialize to JSON (only top 50 positions to save space)
  Map<String, dynamic> toJson() {
    // Get top 50 worst positions (lowest win rate)
    final sortedPositions = getSortedPositions(minGames: 3, sortBy: 'win_rate').take(50).toList();

    return {
      'positionStats': sortedPositions.map((p) => p.toJson()).toList(),
      'games': games.map((g) => g.toJson()).toList(),
      'fenToGameIndices': fenToGameIndices.map(
        (key, value) => MapEntry(key, value),
      ),
    };
  }

  /// Deserialize from JSON
  factory PositionAnalysis.fromJson(Map<String, dynamic> json) {
    final positionStatsList = (json['positionStats'] as List<dynamic>?)
            ?.map((p) => PositionStats.fromJson(p as Map<String, dynamic>))
            .toList() ??
        [];

    final positionStatsMap = <String, PositionStats>{};
    for (final stats in positionStatsList) {
      positionStatsMap[stats.fen] = stats;
    }

    final gamesList = (json['games'] as List<dynamic>?)
            ?.map((g) => GameInfo.fromJson(g as Map<String, dynamic>))
            .toList() ??
        [];

    final fenToGameIndicesMap = (json['fenToGameIndices'] as Map<String, dynamic>?)?.map(
          (key, value) => MapEntry(key, (value as List<dynamic>).cast<int>()),
        ) ??
        {};

    return PositionAnalysis(
      positionStats: positionStatsMap,
      games: gamesList,
      fenToGameIndices: fenToGameIndicesMap,
    );
  }
}
