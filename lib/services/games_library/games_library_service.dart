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

import 'package:path/path.dart' as p;

import '../../utils/atomic_file.dart';
import '../analysis_games_service.dart';
import '../chess_api_urls.dart';
import '../lichess_api_client.dart';
import '../pgn_parsing_service.dart' show splitPgnIntoGames, extractHeaders;
import '../storage/app_paths.dart';
import 'game_filter.dart';

enum GamesPlatform { chesscom, lichess }

/// Downloads a player's raw multi-game PGN. [maxGames] / [since] are hints to
/// the underlying API; final filtering is always re-applied locally.
typedef GameFetcher =
    Future<String> Function(
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
  }) : _chesscom = chesscomFetcher ?? _defaultChesscomFetcher,
       _lichess = lichessFetcher ?? _defaultLichessFetcher;

  final GameFetcher _chesscom;
  final GameFetcher _lichess;
  final Duration cacheTtl;

  /// Games kept per player in the on-disk cache. The cache doubles as the
  /// store for locally written `[%eval]` annotations, so it is deliberately
  /// far larger than any one page of the Games list — but it still has to be
  /// bounded, or a merge-only cache grows forever and every read re-parses
  /// the player's whole history.
  static const int maxCachedGames = 1000;

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

  /// Path of the on-disk cache for this player — the file the PGN viewer
  /// opens when reviewing a game from the Games page (so its `[%eval]`
  /// annotations persist into the same store the list reads).
  Future<String> cacheFilePath(GamesPlatform platform, String username) async =>
      (await _cacheFile(platform, username)).path;

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

    final cacheUsable =
        !forceRefresh &&
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
        if (await file.exists()) {
          // Merge, never overwrite: cached games may carry locally written
          // analysis annotations that a wholesale rewrite would destroy.
          pgn = mergeGamePgns(
            existing: await file.readAsString(),
            fresh: pgn,
            maxGames: maxCachedGames,
          );
        }
        await writeTextFileAtomically(file, pgn);
      } else if (await file.exists()) {
        // Network gave nothing — fall back to the stale cache rather than
        // wiping the user's data.
        pgn = await file.readAsString();
      }
    }

    return selectFromPgn(pgn, selection);
  }

  /// Replace one game's movetext inside a cache file, keeping its headers and
  /// every other game verbatim.
  ///
  /// This is the background auto-analysis write path: unlike the PGN viewer
  /// (which holds the whole file in memory and rewrites it), this reads the
  /// file fresh and patches exactly the game identified by [dedupKey], so
  /// sequential patches compose and nothing else in the file is touched.
  /// Returns false when the file or the game cannot be found.
  static Future<bool> patchGameMovetext({
    required String cachePath,
    required String dedupKey,
    required String updatedMovetext,
  }) async {
    final file = File(cachePath);
    if (!await file.exists()) return false;
    final chunks = splitPgnIntoGames(await file.readAsString());
    for (var i = 0; i < chunks.length; i++) {
      if (dedupKeyForHeaders(extractHeaders(chunks[i])) != dedupKey) continue;
      // The header block is the leading run of `[Tag "value"]` lines. Found
      // by scanning, not by a last-`]`-before-newline regex: wrapped movetext
      // can legitimately end a line on `]` (e.g. after a clock comment).
      final lines = chunks[i].trimRight().split('\n');
      var headerCount = 0;
      while (headerCount < lines.length) {
        final t = lines[headerCount].trim();
        if (!t.startsWith('[') || !t.endsWith(']')) break;
        headerCount++;
      }
      if (headerCount == 0) return false;
      final headers = lines.sublist(0, headerCount).join('\n');
      chunks[i] = '$headers\n\n${updatedMovetext.trim()}';
      await writeTextFileAtomically(
        file,
        '${chunks.map((c) => c.trim()).join('\n\n')}\n',
      );
      return true;
    }
    return false;
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
      monthsBack = (now.year - since.year) * 12 + (now.month - since.month) + 1;
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
      // Clocks feed the tempo flaw tags when these PGNs are re-mined.
      'clocks': 'true',
      'evals': 'false',
    };
    if (since != null) {
      params['since'] = '${since.millisecondsSinceEpoch}';
    }
    final uri = lichessUserGamesUrl(username, params);
    // Through the shared client, not bare http: it enforces the politeness
    // delay, backs off on 429s, and sends the user's auth token.
    final resp = await LichessApiClient.instance.get(
      uri,
      extraHeaders: {'Accept': 'application/x-chess-pgn'},
    );
    if (resp == null || resp.statusCode != 200) return '';
    return resp.body;
  }
}
