import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'dart:io';
import 'dart:convert';

import '../models/analysis_player_info.dart';
import 'lichess_api_client.dart';
import 'pgn_parsing_service.dart';
import '../utils/atomic_file.dart';
import '../utils/file_text_reader.dart';
import 'storage/app_paths.dart';

/// Service for downloading and managing games for position analysis.
///
/// Maintains a separate on-disk store from the imported games used for tactics.
/// Each player's data consists of:
///   • `<key>.pgn`  – raw PGN text
///   • `<key>.json` – [AnalysisPlayerInfo] metadata
///   • `<key>_white_analysis.json` / `<key>_black_analysis.json` – cached analysis
class AnalysisGamesService {
  /// Resolve (and create if needed) the on-disk directory for analysis data.
  Future<Directory> _getAnalysisDirectory() async {
    return AppPaths.analysisGamesDirectory(create: true);
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

    final isDateMode = cutoff != null;

    // Walk backwards from the most recent archive.
    for (int i = archives.length - 1; i >= 0; i--) {
      // In game-count mode, stop once we have enough.
      if (!isDateMode && allGames.length >= maxGames) break;

      // In date-based modes, skip archives outside the requested range.
      if (cutoff != null) {
        final parts = archives[i].split('/');
        if (parts.length >= 2) {
          final year = int.tryParse(parts[parts.length - 2]);
          final month = int.tryParse(parts[parts.length - 1]);
          if (year != null && month != null) {
            if (DateTime(year, month).isBefore(cutoff)) break;
          }
        }
      }

      if (isDateMode) {
        onProgress?.call('${allGames.length} games downloaded so far…');
      } else {
        onProgress?.call(
          '${allGames.length} / $maxGames games downloaded so far…',
        );
      }

      try {
        final response = await http.get(Uri.parse('${archives[i]}/pgn'));
        if (response.statusCode == 200 && response.body.isNotEmpty) {
          for (final game in splitPgnIntoGames(stripBom(response.body))) {
            if (!isDateMode && allGames.length >= maxGames) break;
            if (!_isBulletGame(game)) allGames.add(game);
          }
        }
      } catch (e) {
        onProgress?.call('Error fetching archive: $e');
      }

      // Be polite to the API.
      await Future.delayed(const Duration(milliseconds: 300));
    }

    onProgress?.call('${allGames.length} games downloaded');
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
    onProgress?.call('Downloading games from Lichess…');

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
      final since = DateTime.now()
          .subtract(Duration(days: monthsBack * 30))
          .millisecondsSinceEpoch;
      params['since'] = since.toString();
    } else {
      params['max'] = maxGames.toString();
    }

    final uri = Uri.parse(
      'https://lichess.org/api/games/user/$username',
    ).replace(queryParameters: params);

    final response = await LichessApiClient.instance.get(
      uri,
      extraHeaders: {'Accept': 'application/x-chess-pgn'},
    );

    if (response == null) {
      throw Exception('Failed to fetch Lichess games (request failed)');
    }
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
    }

    final games = splitPgnIntoGames(stripBom(response.body));
    onProgress?.call('${games.length} games downloaded');
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
    final gameCount = countPgnGames(pgns);

    // Write PGN.
    await writeTextFileAtomically(
      File(p.join(directory.path, '$key.pgn')),
      pgns,
    );

    // Write metadata.
    final info = AnalysisPlayerInfo(
      platform: platform,
      username: username,
      maxGames: maxGames,
      monthsBack: monthsBack,
      downloadedAt: DateTime.now(),
      gameCount: gameCount,
    );
    await writeTextFileAtomically(
      File(p.join(directory.path, '$key.json')),
      json.encode(info.toJson()),
    );

    // Invalidate stale cached analysis so it gets rebuilt on next view.
    await clearCachedAnalysis(platform, username);

    return info;
  }

  String _playerKey(String platform, String username) {
    return AnalysisPlayerInfo(platform: platform, username: username).playerKey;
  }

  /// Absolute path of the raw PGN file for [username] on [platform].
  ///
  /// Exposed so the analysis build isolate can read the file itself instead
  /// of the UI thread loading and splitting the whole corpus.
  Future<String> analysisPgnPath(String platform, String username) async {
    final directory = await _getAnalysisDirectory();
    return p.join(directory.path, '${_playerKey(platform, username)}.pgn');
  }

  /// Absolute path of the cached-analysis file for one colour, written and
  /// read by [UnifiedAnalysisBuilder]'s isolate entry points.
  Future<String> cachedAnalysisPath(
    String platform,
    String username,
    bool isWhite,
  ) async {
    final directory = await _getAnalysisDirectory();
    final colour = isWhite ? 'white' : 'black';
    return p.join(
      directory.path,
      '${_playerKey(platform, username)}_${colour}_analysis.json',
    );
  }

  /// Absolute path of the hole-hunt report for one colour's game tree,
  /// written and read via [HoleHuntPersistence].
  Future<String> holesReportPath(
    String platform,
    String username,
    bool isWhite,
  ) async {
    final directory = await _getAnalysisDirectory();
    final colour = isWhite ? 'white' : 'black';
    return p.join(
      directory.path,
      '${_playerKey(platform, username)}_holes_$colour.json',
    );
  }

  /// Load the raw PGN for [username] on [platform]. Returns `null` on miss.
  Future<String?> loadAnalysisGames(String platform, String username) async {
    try {
      final file = File(await analysisPgnPath(platform, username));
      return await file.exists() ? readTextFile(file) : null;
    } catch (_) {
      return null;
    }
  }

  /// List every cached player, most-recently-downloaded first.
  Future<List<AnalysisPlayerInfo>> getAllCachedPlayers() async {
    try {
      final directory = await _getAnalysisDirectory();
      final metadataFiles = <File>[
        await for (final entity in directory.list())
          if (entity is File &&
              entity.path.endsWith('.json') &&
              !entity.path.contains('_analysis.json'))
            entity,
      ];

      final players = (await Future.wait(
        metadataFiles.map((file) async {
          try {
            final content = await file.readAsString();
            return AnalysisPlayerInfo.fromJson(
              json.decode(content) as Map<String, dynamic>,
            );
          } catch (_) {
            // Skip corrupt metadata files.
            return null;
          }
        }),
      )).whereType<AnalysisPlayerInfo>().toList();

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
      '_engine_evals.json',
      '_holes_white.json',
      '_holes_black.json',
    ]) {
      final file = File(p.join(directory.path, '$key$suffix'));
      if (await file.exists()) await file.delete();
    }
  }

  // ── Analysis cache ─────────────────────────────────────────────────
  //
  // The cache files themselves are written and read by
  // [UnifiedAnalysisBuilder]'s isolate entry points (via
  // [cachedAnalysisPath]) so the JSON work never touches the UI thread;
  // this service only handles invalidation.

  /// Remove cached analysis for both colours (e.g. after a re-download).
  /// Hole-hunt reports are built from the same games, so they go stale (and
  /// are removed) together with the analysis.
  Future<void> clearCachedAnalysis(String platform, String username) async {
    for (final isWhite in [true, false]) {
      for (final path in [
        await cachedAnalysisPath(platform, username, isWhite),
        await holesReportPath(platform, username, isWhite),
      ]) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    }
  }

  // ── Engine eval cache ───────────────────────────────────────────────

  /// Persist engine weakness results for a player.
  Future<void> saveEngineEvals(
    String platform,
    String username,
    List<Map<String, dynamic>> evals,
  ) async {
    final directory = await _getAnalysisDirectory();
    final key = AnalysisPlayerInfo(
      platform: platform,
      username: username,
    ).playerKey;

    await writeTextFileAtomically(
      File(p.join(directory.path, '${key}_engine_evals.json')),
      json.encode(evals),
    );
  }

  /// Load engine weakness results. Returns `null` on miss.
  Future<List<dynamic>?> loadEngineEvals(
    String platform,
    String username,
  ) async {
    try {
      final directory = await _getAnalysisDirectory();
      final key = AnalysisPlayerInfo(
        platform: platform,
        username: username,
      ).playerKey;
      final file = File(p.join(directory.path, '${key}_engine_evals.json'));

      if (!await file.exists()) return null;
      return json.decode(await file.readAsString()) as List<dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ── Utilities ──────────────────────────────────────────────────────

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
