/// Unified Games library — one download, one on-disk cache, one filter, shared
/// by tactics / weakness-finder / repertoire builder.
///
/// The point is to stop re-downloading the same player's games three times.
/// A raw per-(platform, username) PGN is cached under
/// [AppPaths.gamesLibraryDirectory]; callers ask for a *slice* of it via a
/// [GameSelection] and get back filtered [GameRecord]s without touching the
/// network if a fresh-enough cache exists.
///
/// Fetching is injected ([GameFetcher]) so the cache + selection plumbing is
/// decoupled from the network and from the platform-specific download code
/// that already exists ([AnalysisGamesService] for Chess.com).
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../analysis_games_service.dart';
import '../storage/app_paths.dart';
import 'game_filter.dart';

enum GamesPlatform { chesscom, lichess }

/// Downloads a player's raw multi-game PGN. [maxGames] / [since] are hints to
/// the underlying API; final filtering is always re-applied locally.
typedef GameFetcher = Future<String> Function(
  String username, {
  int maxGames,
  DateTime? since,
  void Function(String message)? onProgress,
});

class GamesLibraryService {
  GamesLibraryService({
    GameFetcher? chesscomFetcher,
    GameFetcher? lichessFetcher,
    this.cacheTtl = const Duration(hours: 12),
  })  : _chesscom = chesscomFetcher ?? _defaultChesscomFetcher,
        _lichess = lichessFetcher ?? _defaultLichessFetcher;

  final GameFetcher _chesscom;
  final GameFetcher _lichess;
  final Duration cacheTtl;

  GameFetcher _fetcherFor(GamesPlatform platform) =>
      platform == GamesPlatform.chesscom ? _chesscom : _lichess;

  /// Pure entry point: parse + filter an already-fetched PGN. Tested directly.
  static List<GameRecord> selectFromPgn(String pgn, GameSelection selection) =>
      applySelection(parseGameRecords(pgn), selection);

  Future<File> _cacheFile(GamesPlatform platform, String username) async {
    final dir = await AppPaths.gamesLibraryDirectory(create: true);
    final safe = username.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_');
    return File(p.join(dir.path, '${platform.name}_$safe.pgn'));
  }

  /// Whether a usable cache file already exists (within TTL when
  /// [respectTtl]).
  Future<bool> hasFreshCache(
    GamesPlatform platform,
    String username, {
    bool respectTtl = true,
  }) async {
    final file = await _cacheFile(platform, username);
    if (!await file.exists()) return false;
    if (!respectTtl) return true;
    final age = DateTime.now().difference(await file.lastModified());
    return age <= cacheTtl;
  }

  /// Return the requested slice of a player's games.
  ///
  /// Uses the on-disk cache when fresh (or when [forceRefresh] is false and a
  /// cache exists offline); otherwise fetches, caches, then filters.
  Future<List<GameRecord>> getGames({
    required GamesPlatform platform,
    required String username,
    GameSelection selection = const GameSelection(),
    bool forceRefresh = false,
    void Function(String message)? onProgress,
  }) async {
    final file = await _cacheFile(platform, username);
    String pgn;

    final cacheUsable = !forceRefresh &&
        await hasFreshCache(platform, username, respectTtl: !forceRefresh);
    if (cacheUsable) {
      pgn = await file.readAsString();
    } else {
      onProgress?.call('Downloading $username from ${platform.name}…');
      pgn = await _fetcherFor(platform)(
        username,
        maxGames: selection.maxGames ?? 300,
        since: selection.since,
        onProgress: onProgress,
      );
      if (pgn.trim().isNotEmpty) {
        await file.writeAsString(pgn, flush: true);
      } else if (await file.exists()) {
        // Network gave nothing — fall back to the stale cache rather than
        // wiping the user's data.
        pgn = await file.readAsString();
      }
    }

    return selectFromPgn(pgn, selection);
  }

  // ── Default fetchers ────────────────────────────────────────────────

  static Future<String> _defaultChesscomFetcher(
    String username, {
    int maxGames = 300,
    DateTime? since,
    void Function(String message)? onProgress,
  }) {
    int? monthsBack;
    if (since != null) {
      final now = DateTime.now();
      monthsBack =
          (now.year - since.year) * 12 + (now.month - since.month) + 1;
      if (monthsBack < 1) monthsBack = 1;
    }
    return AnalysisGamesService().downloadChesscomGames(
      username,
      maxGames: maxGames,
      monthsBack: monthsBack,
      onProgress: onProgress,
    );
  }

  static Future<String> _defaultLichessFetcher(
    String username, {
    int maxGames = 300,
    DateTime? since,
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('Fetching Lichess games for $username…');
    final params = <String, String>{
      'max': '$maxGames',
      'perfType': 'bullet,blitz,rapid,classical',
      'clocks': 'false',
      'evals': 'false',
    };
    if (since != null) {
      params['since'] = '${since.millisecondsSinceEpoch}';
    }
    final uri = Uri.parse('https://lichess.org/api/games/user/$username')
        .replace(queryParameters: params);
    final resp = await http.get(uri, headers: {'Accept': 'application/x-chess-pgn'});
    if (resp.statusCode != 200) return '';
    return resp.body;
  }
}
