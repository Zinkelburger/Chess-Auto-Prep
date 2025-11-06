import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';

/// Service for downloading and managing games specifically for position analysis
/// Separate from the imported games used for tactics
/// Supports multiple cached player game sets
class AnalysisGamesService {
  static const String _analysisGamesDir = 'analysis_games';

  /// Get unique key for a player's game set
  String _getPlayerKey(String platform, String username) {
    return '${platform}_${username.toLowerCase()}';
  }

  /// Get directory for analysis games
  Future<Directory> _getAnalysisDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final analysisDir = Directory('${appDir.path}/$_analysisGamesDir');
    if (!await analysisDir.exists()) {
      await analysisDir.create(recursive: true);
    }
    return analysisDir;
  }

  /// Download games from Chess.com, excluding bullet
  Future<String> downloadChesscomGames(
    String username, {
    int monthsBack = 3,
    Function(String)? progressCallback,
  }) async {
    progressCallback?.call('Downloading Chess.com games for $username (last $monthsBack months)...');

    final now = DateTime.now();

    // Generate list of months to fetch
    final List<DateTime> months = [];
    for (int i = 0; i < monthsBack; i++) {
      final monthDate = DateTime(now.year, now.month - i);
      months.add(monthDate);
    }

    final List<String> allGames = [];

    for (final month in months) {
      final url = 'https://api.chess.com/pub/player/${username.toLowerCase()}/games/${month.year}/${month.month.toString().padLeft(2, '0')}/pgn';

      progressCallback?.call('Fetching games from ${month.year}-${month.month}...');

      try {
        final response = await http.get(Uri.parse(url));

        if (response.statusCode != 200) {
          progressCallback?.call('Warning: Failed to fetch games from ${month.year}-${month.month}');
          continue;
        }

        // Split PGN into individual games
        final games = _splitPgnIntoGames(response.body);

        // Filter out bullet games (< 180 seconds)
        int filtered = 0;
        for (final game in games) {
          if (!_isBulletGame(game)) {
            allGames.add(game);
          } else {
            filtered++;
          }
        }

        progressCallback?.call('Found ${games.length} games ($filtered bullet games filtered)');

      } catch (e) {
        progressCallback?.call('Error fetching ${month.year}-${month.month}: $e');
      }

      // Be polite to the API
      await Future.delayed(const Duration(milliseconds: 500));
    }

    progressCallback?.call('Downloaded ${allGames.length} non-bullet games from Chess.com');
    return allGames.join('\n\n');
  }

  /// Download games from Lichess with filters
  Future<String> downloadLichessGames(
    String username, {
    int? monthsBack = 3,
    Function(String)? progressCallback,
  }) async {
    progressCallback?.call('Downloading Lichess games for $username...');

    // Calculate timestamp for 3 months ago
    final now = DateTime.now();
    final threeMonthsAgo = DateTime(now.year, now.month - (monthsBack ?? 3));
    final sinceTimestamp = threeMonthsAgo.millisecondsSinceEpoch;

    // Build URL with query parameters
    final params = {
      'since': sinceTimestamp.toString(),
      'perfType': 'blitz,rapid,classical,correspondence', // Exclude bullet
      'moves': 'true',
      'tags': 'true',
      'clocks': 'false',
      'evals': 'false',
      'opening': 'true',
      'sort': 'dateDesc',
    };

    final uri = Uri.parse('https://lichess.org/api/games/user/$username').replace(queryParameters: params);

    try {
      progressCallback?.call('Fetching games from Lichess API...');

      final response = await http.get(
        uri,
        headers: {
          'Accept': 'application/x-chess-pgn',
        },
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
      }

      // Count games
      final games = _splitPgnIntoGames(response.body);
      progressCallback?.call('Downloaded ${games.length} games from Lichess');

      return response.body;

    } catch (e) {
      progressCallback?.call('Error downloading from Lichess: $e');
      rethrow;
    }
  }

  /// Save analysis games to persistent storage
  Future<void> saveAnalysisGames(
    String pgns,
    String platform,
    String username,
    int monthsBack,
  ) async {
    final directory = await _getAnalysisDirectory();
    final playerKey = _getPlayerKey(platform, username);

    // Save PGN file
    final pgnFile = File('${directory.path}/$playerKey.pgn');
    await pgnFile.writeAsString(pgns);

    // Save metadata
    final metadata = {
      'platform': platform,
      'username': username,
      'monthsBack': monthsBack,
      'downloadedAt': DateTime.now().toIso8601String(),
      'gameCount': _splitPgnIntoGames(pgns).length,
    };

    final metadataFile = File('${directory.path}/$playerKey.json');
    await metadataFile.writeAsString(json.encode(metadata));
  }

  /// Load analysis games for a specific player
  Future<String?> loadAnalysisGames(String platform, String username) async {
    try {
      final directory = await _getAnalysisDirectory();
      final playerKey = _getPlayerKey(platform, username);
      final pgnFile = File('${directory.path}/$playerKey.pgn');

      if (!await pgnFile.exists()) {
        return null;
      }

      return await pgnFile.readAsString();
    } catch (e) {
      // Error loading analysis games: $e
      return null;
    }
  }

  /// Get metadata for a specific player
  Future<Map<String, dynamic>?> getAnalysisMetadata(String platform, String username) async {
    try {
      final directory = await _getAnalysisDirectory();
      final playerKey = _getPlayerKey(platform, username);
      final metadataFile = File('${directory.path}/$playerKey.json');

      if (!await metadataFile.exists()) {
        return null;
      }

      final content = await metadataFile.readAsString();
      return json.decode(content) as Map<String, dynamic>;
    } catch (e) {
      // Error loading analysis metadata: $e
      return null;
    }
  }

  /// Get all cached player game sets
  Future<List<Map<String, dynamic>>> getAllCachedPlayers() async {
    try {
      final directory = await _getAnalysisDirectory();

      final List<Map<String, dynamic>> players = [];

      await for (final entity in directory.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          try {
            final content = await entity.readAsString();
            final metadata = json.decode(content) as Map<String, dynamic>;
            players.add(metadata);
          } catch (e) {
            // Skip invalid metadata files
          }
        }
      }

      // Sort by download date (most recent first)
      players.sort((a, b) {
        final aDate = DateTime.tryParse(a['downloadedAt'] as String? ?? '');
        final bDate = DateTime.tryParse(b['downloadedAt'] as String? ?? '');
        if (aDate == null || bDate == null) return 0;
        return bDate.compareTo(aDate);
      });

      return players;
    } catch (e) {
      return [];
    }
  }

  /// Check if any analysis games exist
  Future<bool> hasAnyAnalysisGames() async {
    final players = await getAllCachedPlayers();
    return players.isNotEmpty;
  }

  /// Check if specific player games exist
  Future<bool> hasAnalysisGames(String platform, String username) async {
    final directory = await _getAnalysisDirectory();
    final playerKey = _getPlayerKey(platform, username);
    final pgnFile = File('${directory.path}/$playerKey.pgn');
    return await pgnFile.exists();
  }

  /// Delete specific player's games
  Future<void> deleteAnalysisGames(String platform, String username) async {
    final directory = await _getAnalysisDirectory();
    final playerKey = _getPlayerKey(platform, username);

    final pgnFile = File('${directory.path}/$playerKey.pgn');
    if (await pgnFile.exists()) {
      await pgnFile.delete();
    }

    final metadataFile = File('${directory.path}/$playerKey.json');
    if (await metadataFile.exists()) {
      await metadataFile.delete();
    }

    // Delete cached analysis files
    final whiteCacheFile = File('${directory.path}/${playerKey}_white_analysis.json');
    if (await whiteCacheFile.exists()) {
      await whiteCacheFile.delete();
    }

    final blackCacheFile = File('${directory.path}/${playerKey}_black_analysis.json');
    if (await blackCacheFile.exists()) {
      await blackCacheFile.delete();
    }
  }

  /// Save cached analysis for a player and color
  Future<void> saveCachedAnalysis(
    String platform,
    String username,
    bool isWhite,
    Map<String, dynamic> analysisData,
  ) async {
    final directory = await _getAnalysisDirectory();
    final playerKey = _getPlayerKey(platform, username);
    final colorSuffix = isWhite ? 'white' : 'black';
    final cacheFile = File('${directory.path}/${playerKey}_${colorSuffix}_analysis.json');

    await cacheFile.writeAsString(json.encode(analysisData));
  }

  /// Load cached analysis for a player and color
  Future<Map<String, dynamic>?> loadCachedAnalysis(
    String platform,
    String username,
    bool isWhite,
  ) async {
    try {
      final directory = await _getAnalysisDirectory();
      final playerKey = _getPlayerKey(platform, username);
      final colorSuffix = isWhite ? 'white' : 'black';
      final cacheFile = File('${directory.path}/${playerKey}_${colorSuffix}_analysis.json');

      if (!await cacheFile.exists()) {
        return null;
      }

      final content = await cacheFile.readAsString();
      return json.decode(content) as Map<String, dynamic>;
    } catch (e) {
      // Error loading cached analysis
      return null;
    }
  }

  /// Check if cached analysis exists
  Future<bool> hasCachedAnalysis(
    String platform,
    String username,
    bool isWhite,
  ) async {
    final directory = await _getAnalysisDirectory();
    final playerKey = _getPlayerKey(platform, username);
    final colorSuffix = isWhite ? 'white' : 'black';
    final cacheFile = File('${directory.path}/${playerKey}_${colorSuffix}_analysis.json');
    return await cacheFile.exists();
  }

  /// Helper: Split PGN text into individual games
  List<String> _splitPgnIntoGames(String pgn) {
    final games = <String>[];
    final lines = pgn.split('\n');

    String currentGame = '';
    bool inGame = false;

    for (final line in lines) {
      if (line.startsWith('[Event')) {
        if (inGame && currentGame.isNotEmpty) {
          games.add(currentGame.trim());
        }
        currentGame = '$line\n';
        inGame = true;
      } else if (inGame) {
        currentGame += '$line\n';
      }
    }

    if (inGame && currentGame.isNotEmpty) {
      games.add(currentGame.trim());
    }

    return games;
  }

  /// Helper: Check if a game is bullet (< 3 minutes main time)
  bool _isBulletGame(String pgn) {
    // Look for TimeControl tag like [TimeControl "180+0"]
    final timeControlRegex = RegExp(r'\[TimeControl "(\d+)\+\d+"\]');
    final match = timeControlRegex.firstMatch(pgn);

    if (match != null) {
      final mainTime = int.tryParse(match.group(1) ?? '');
      if (mainTime != null && mainTime < 180) {
        return true; // Bullet game
      }
    }

    return false;
  }
}
