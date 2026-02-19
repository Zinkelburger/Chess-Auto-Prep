import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';

import '../models/analysis_player_info.dart';
import 'lichess_auth_service.dart';

/// Service for downloading and managing games for position analysis.
///
/// Maintains a separate on-disk store from the imported games used for tactics.
/// Each player's data consists of:
///   • `<key>.pgn`  – raw PGN text
///   • `<key>.json` – [AnalysisPlayerInfo] metadata
///   • `<key>_white_analysis.json` / `<key>_black_analysis.json` – cached analysis
class AnalysisGamesService {
  static const String _analysisGamesDir = 'analysis_games';

  /// Resolve (and create if needed) the on-disk directory for analysis data.
  Future<Directory> _getAnalysisDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final analysisDir = Directory('${appDir.path}/$_analysisGamesDir');
    if (!await analysisDir.exists()) {
      await analysisDir.create(recursive: true);
    }
    return analysisDir;
  }

  // ── Downloads ──────────────────────────────────────────────────────

  /// Fetch the list of monthly archive URLs from Chess.com.
  ///
  /// Returns the URLs in chronological order (oldest first), or an empty
  /// list if the player has no archives.
  Future<List<String>> _fetchChesscomArchives(String username) async {
    final url = Uri.parse(
      'https://api.chess.com/pub/player/${username.toLowerCase()}'
      '/games/archives',
    );
    final response = await http.get(url);
    if (response.statusCode != 200) return [];
    final data = json.decode(response.body) as Map<String, dynamic>;
    return List<String>.from(data['archives'] as List);
  }

  /// Download games from Chess.com, excluding bullet.
  ///
  /// Uses the Chess.com archives endpoint to discover which months actually
  /// have games, avoiding wasted requests to empty months and reliably
  /// finding games for inactive players.
  ///
  /// Two modes controlled by [monthsBack]:
  ///   • `null` (game-count mode) – walk backwards through every available
  ///     archive, stop at [maxGames] non-bullet games.
  ///   • non-null (months mode) – fetch only archives that fall within the
  ///     last [monthsBack] calendar months.
  Future<String> downloadChesscomGames(
    String username, {
    int maxGames = 100,
    int? monthsBack,
    void Function(String)? onProgress,
  }) async {
    onProgress?.call('Fetching Chess.com game archives for $username…');

    // Fetch the list of months that actually have games.
    final archives = await _fetchChesscomArchives(username);
    if (archives.isEmpty) {
      onProgress?.call('No game archives found for $username');
      return '';
    }

    final now = DateTime.now();
    final allGames = <String>[];

    // In months mode, compute the earliest allowed archive date.
    // E.g. monthsBack=6 and now=2026-02 → cutoff = 2025-09.
    DateTime? cutoff;
    if (monthsBack != null) {
      cutoff = DateTime(now.year, now.month - monthsBack + 1);
    }

    // Walk backwards from the most recent archive.
    for (int i = archives.length - 1; i >= 0; i--) {
      // In game-count mode, stop once we have enough.
      if (monthsBack == null && allGames.length >= maxGames) break;

      // In months mode, skip archives outside the requested date range.
      if (cutoff != null) {
        // Parse year/month from the archive URL (e.g. .../games/2025/07).
        final parts = archives[i].split('/');
        if (parts.length >= 2) {
          final year = int.tryParse(parts[parts.length - 2]);
          final month = int.tryParse(parts[parts.length - 1]);
          if (year != null && month != null) {
            if (DateTime(year, month).isBefore(cutoff)) break;
          }
        }
      }

      if (monthsBack != null) {
        onProgress?.call(
          'Fetching archive ${archives.length - i}… '
          '(${allGames.length} games so far)',
        );
      } else {
        onProgress?.call(
          'Fetching archive ${archives.length - i}… '
          '(${allGames.length}/$maxGames)',
        );
      }

      try {
        final response = await http.get(Uri.parse('${archives[i]}/pgn'));
        if (response.statusCode == 200 && response.body.isNotEmpty) {
          for (final game in splitPgnIntoGames(response.body)) {
            if (monthsBack == null && allGames.length >= maxGames) break;
            if (!_isBulletGame(game)) allGames.add(game);
          }
        }
      } catch (e) {
        onProgress?.call('Error fetching archive: $e');
      }

      // Be polite to the API.
      await Future.delayed(const Duration(milliseconds: 300));
    }

    onProgress?.call('Downloaded ${allGames.length} non-bullet games');
    return allGames.join('\n\n');
  }

  /// Download games from Lichess, excluding bullet.
  ///
  /// Two modes controlled by [monthsBack]:
  ///   • `null` (game-count mode) – uses the `max` API parameter.
  ///   • non-null (months mode) – uses the `since` API parameter with a
  ///     timestamp [monthsBack] months in the past.
  Future<String> downloadLichessGames(
    String username, {
    int maxGames = 100,
    int? monthsBack,
    void Function(String)? onProgress,
  }) async {
    onProgress?.call('Fetching Lichess games for $username…');

    final params = <String, String>{
      'perfType': 'blitz,rapid,classical,correspondence',
      'moves': 'true',
      'tags': 'true',
      'clocks': 'false',
      'evals': 'false',
      'opening': 'true',
      'sort': 'dateDesc',
    };

    if (monthsBack != null) {
      // Calculate a timestamp N months ago (approximate: 30 days/month).
      final since = DateTime.now()
          .subtract(Duration(days: monthsBack * 30))
          .millisecondsSinceEpoch;
      params['since'] = since.toString();
      onProgress?.call(
        'Downloading games from the last $monthsBack months…',
      );
    } else {
      params['max'] = maxGames.toString();
      onProgress?.call('Downloading up to $maxGames games…');
    }

    final uri = Uri.parse('https://lichess.org/api/games/user/$username')
        .replace(queryParameters: params);

    final headers = await LichessAuthService().getHeaders(
      {'Accept': 'application/x-chess-pgn'},
    );
    final response = await http.get(uri, headers: headers);

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
    }

    final games = splitPgnIntoGames(response.body);
    onProgress?.call('Downloaded ${games.length} games');
    return response.body;
  }

  // ── Persistence ────────────────────────────────────────────────────

  /// Save downloaded PGN + metadata. Also **clears** any stale cached analysis
  /// so the next view triggers a fresh rebuild. Returns the saved info.
  Future<AnalysisPlayerInfo> saveAnalysisGames(
    String pgns, {
    required String platform,
    required String username,
    required int maxGames,
    int? monthsBack,
  }) async {
    final directory = await _getAnalysisDirectory();
    final key = AnalysisPlayerInfo(
      platform: platform,
      username: username,
    ).playerKey;
    final gameCount = splitPgnIntoGames(pgns).length;

    // Write PGN.
    await File('${directory.path}/$key.pgn').writeAsString(pgns);

    // Write metadata.
    final info = AnalysisPlayerInfo(
      platform: platform,
      username: username,
      maxGames: maxGames,
      monthsBack: monthsBack,
      downloadedAt: DateTime.now(),
      gameCount: gameCount,
    );
    await File('${directory.path}/$key.json')
        .writeAsString(json.encode(info.toJson()));

    // Invalidate stale cached analysis so it gets rebuilt on next view.
    await clearCachedAnalysis(platform, username);

    return info;
  }

  /// Load the raw PGN for [username] on [platform]. Returns `null` on miss.
  Future<String?> loadAnalysisGames(String platform, String username) async {
    try {
      final directory = await _getAnalysisDirectory();
      final key = AnalysisPlayerInfo(
        platform: platform,
        username: username,
      ).playerKey;
      final file = File('${directory.path}/$key.pgn');
      return await file.exists() ? file.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  /// List every cached player, most-recently-downloaded first.
  Future<List<AnalysisPlayerInfo>> getAllCachedPlayers() async {
    try {
      final directory = await _getAnalysisDirectory();
      final players = <AnalysisPlayerInfo>[];

      await for (final entity in directory.list()) {
        if (entity is File &&
            entity.path.endsWith('.json') &&
            !entity.path.contains('_analysis.json')) {
          try {
            final content = await entity.readAsString();
            players.add(
              AnalysisPlayerInfo.fromJson(
                json.decode(content) as Map<String, dynamic>,
              ),
            );
          } catch (_) {
            // Skip corrupt metadata files.
          }
        }
      }

      players.sort((a, b) {
        final aDate = a.downloadedAt;
        final bDate = b.downloadedAt;
        if (aDate == null || bDate == null) return 0;
        return bDate.compareTo(aDate);
      });

      return players;
    } catch (_) {
      return [];
    }
  }

  /// Remove **all** on-disk data for a player (PGN, metadata, cached analysis).
  Future<void> deletePlayerData(String platform, String username) async {
    final directory = await _getAnalysisDirectory();
    final key = AnalysisPlayerInfo(
      platform: platform,
      username: username,
    ).playerKey;

    for (final suffix in [
      '.pgn',
      '.json',
      '_white_analysis.json',
      '_black_analysis.json',
    ]) {
      final file = File('${directory.path}/$key$suffix');
      if (await file.exists()) await file.delete();
    }
  }

  // ── Analysis cache ─────────────────────────────────────────────────

  /// Persist computed analysis for a player + colour.
  Future<void> saveCachedAnalysis(
    String platform,
    String username,
    bool isWhite,
    Map<String, dynamic> analysisData,
  ) async {
    final directory = await _getAnalysisDirectory();
    final key = AnalysisPlayerInfo(
      platform: platform,
      username: username,
    ).playerKey;
    final colour = isWhite ? 'white' : 'black';

    await File('${directory.path}/${key}_${colour}_analysis.json')
        .writeAsString(json.encode(analysisData));
  }

  /// Load cached analysis for a player + colour. Returns `null` on miss.
  Future<Map<String, dynamic>?> loadCachedAnalysis(
    String platform,
    String username,
    bool isWhite,
  ) async {
    try {
      final directory = await _getAnalysisDirectory();
      final key = AnalysisPlayerInfo(
        platform: platform,
        username: username,
      ).playerKey;
      final colour = isWhite ? 'white' : 'black';
      final file =
          File('${directory.path}/${key}_${colour}_analysis.json');

      if (!await file.exists()) return null;
      return json.decode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Remove cached analysis for both colours (e.g. after a re-download).
  Future<void> clearCachedAnalysis(String platform, String username) async {
    final directory = await _getAnalysisDirectory();
    final key = AnalysisPlayerInfo(
      platform: platform,
      username: username,
    ).playerKey;

    for (final colour in ['white', 'black']) {
      final file =
          File('${directory.path}/${key}_${colour}_analysis.json');
      if (await file.exists()) await file.delete();
    }
  }

  // ── Utilities ──────────────────────────────────────────────────────

  /// Split a multi-game PGN string into individual game strings.
  ///
  /// This is a static utility so callers outside the service can reuse it
  /// without duplicating the logic.
  static List<String> splitPgnIntoGames(String pgn) {
    final games = <String>[];
    final lines = pgn.split('\n');
    final buffer = StringBuffer();
    bool inGame = false;

    for (final line in lines) {
      if (line.startsWith('[Event')) {
        if (inGame && buffer.isNotEmpty) {
          games.add(buffer.toString().trim());
          buffer.clear();
        }
        buffer.writeln(line);
        inGame = true;
      } else if (inGame) {
        buffer.writeln(line);
      }
    }

    if (inGame && buffer.isNotEmpty) {
      games.add(buffer.toString().trim());
    }

    return games;
  }

  /// Returns `true` if the PGN's TimeControl is under 3 minutes (bullet).
  bool _isBulletGame(String pgn) {
    final match = RegExp(r'\[TimeControl "(\d+)\+\d+"\]').firstMatch(pgn);
    if (match != null) {
      final mainTime = int.tryParse(match.group(1) ?? '');
      if (mainTime != null && mainTime < 180) return true;
    }
    return false;
  }
}
