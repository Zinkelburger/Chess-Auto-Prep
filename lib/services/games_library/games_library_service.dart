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

import '../pgn_document_patch.dart';

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../utils/atomic_file.dart';
import '../analysis_games_service.dart';
import '../chess_api_urls.dart';
import '../lichess_api_client.dart';
import '../pgn_parsing_service.dart' show splitPgnIntoGames, extractHeaders;
import '../game_store/game_store.dart';
import '../game_store/game_store_service.dart';
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

  /// Parse once, keep the union of several selections' slices (see
  /// [applySelectionUnion]).
  static List<GameRecord> selectFromPgnUnion(
    String pgn,
    List<GameSelection> selections,
  ) => applySelectionUnion(parseGameRecords(pgn), selections);

  static String _usernameKey(String username) =>
      username.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_');

  Future<File> _cacheFile(GamesPlatform platform, String username) async {
    final dir = await AppPaths.gamesLibraryDirectory(create: true);
    return File(
      p.join(dir.path, '${platform.name}_${_usernameKey(username)}.pgn'),
    );
  }

  /// Path of the on-disk cache for this player — the file the PGN viewer
  /// opens when reviewing a game from the Games page (so its `[%eval]`
  /// annotations persist into the same store the list reads).
  Future<String> cacheFilePath(GamesPlatform platform, String username) async =>
      (await _cacheFile(platform, username)).path;

  /// Sidecar recording when this player's cache was last *downloaded*.
  ///
  /// Not the PGN's own mtime: the background engine pass rewrites the cache
  /// in place ([patchGameMovetext]) to store `[%eval]` annotations, so the
  /// file's timestamp answers "last analysed", not "last fetched" — and the
  /// accounts card that reports it would drift a little further from the
  /// truth with every game reviewed.
  File _fetchStampFile(File cache) => File('${cache.path}.fetched');

  Future<void> _writeFetchStamp(File cache, DateTime at) async {
    try {
      await writeTextFileAtomically(
        _fetchStampFile(cache),
        '${at.millisecondsSinceEpoch}',
      );
    } catch (_) {
      // A missing stamp costs a label, never a load.
    }
  }

  /// When [cache]'s games came down, or null if this player has none yet.
  ///
  /// Falls back to the cache file's mtime for players whose games were
  /// downloaded before the sidecar existed: an over-estimate at worst (an
  /// analysis pass may have touched it since), and it self-corrects on the
  /// next real fetch.
  Future<DateTime?> _readFetchStamp(File cache) async {
    try {
      final stamp = _fetchStampFile(cache);
      if (await stamp.exists()) {
        final ms = int.tryParse((await stamp.readAsString()).trim());
        if (ms != null) return DateTime.fromMillisecondsSinceEpoch(ms);
      }
      if (await cache.exists()) return await cache.lastModified();
    } catch (_) {
      // Fall through: no date is better than a wrong one.
    }
    return null;
  }

  /// When this player's games were last downloaded, or null if never.
  Future<DateTime?> lastFetched(
    GamesPlatform platform,
    String username,
  ) async => _readFetchStamp(await _cacheFile(platform, username));

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
  ///
  /// [unionWith] adds further selections whose slices are unioned into the
  /// result from the same parse: one load that leaves the caller holding
  /// several windows' games at once. Only [selection] drives the network
  /// fetch hint — the extra selections are served from whatever the cache
  /// holds, exactly as a later call with them would have been.
  Future<List<GameRecord>> getGames({
    required GamesPlatform platform,
    required String username,
    GameSelection selection = const GameSelection(),
    List<GameSelection> unionWith = const [],
    bool forceRefresh = false,
    void Function(String message)? onProgress,
    void Function(DateTime fetchedAt)? onFetched,
  }) async {
    final file = await _cacheFile(platform, username);
    String pgn;
    DateTime? fetchedNow;

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
        final fresh = pgn;
        pgn = await updateTextFileAtomically(
          file,
          (existing) => existing == null
              ? fresh
              : mergeGamePgns(
                  existing: existing,
                  fresh: fresh,
                  maxGames: maxCachedGames,
                ),
        );
        fetchedNow = DateTime.now();
        await _writeFetchStamp(file, fetchedNow);
      } else if (await file.exists()) {
        // Network gave nothing — fall back to the stale cache rather than
        // wiping the user's data.
        pgn = await file.readAsString();
      }
    }

    // Reported on every load, not only on a download: served from a fresh
    // cache the games are still *there*, and a caller that only heard about
    // network fetches would tell the user "not downloaded yet" while showing
    // them the games.
    if (onFetched != null) {
      final at = fetchedNow ?? await _readFetchStamp(file);
      if (at != null) onFetched(at);
    }

    await _mirrorToStore(platform, username, file, pgn);
    return selectFromPgnUnion(pgn, [selection, ...unionWith]);
  }

  /// Keep the games database's `library:` collection equal to the cache
  /// file, which stays the working copy (the PGN viewer edits it by path).
  /// Runs only when the file is newer than the last mirror, off the UI
  /// isolate, and never fails a load.
  Future<void> _mirrorToStore(
    GamesPlatform platform,
    String username,
    File file,
    String pgn,
  ) async {
    if (pgn.trim().isEmpty) return;
    try {
      final collection = GameCollections.library(
        platform.name,
        _usernameKey(username),
      );
      final store = await GameStoreService.instance.open();
      final mirrored = store.collectionUpdatedAt(collection);
      final modified = await file.exists()
          ? await file.lastModified()
          : DateTime.now();
      if (mirrored != null && !modified.isAfter(mirrored)) return;
      await GameStoreService.instance.importPgnInBackground(
        collection: collection,
        pgnText: pgn,
        replace: true,
      );
    } catch (_) {
      // Mirror is a convenience index; the file is authoritative.
    }
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
    final patched = await patchGameMovetexts(
      cachePath: cachePath,
      movetextByDedupKey: {dedupKey: updatedMovetext},
    );
    return patched == 1;
  }

  /// [patchGameMovetext] for a whole batch: one read, one write, however many
  /// games are being patched. Returns how many were found and replaced.
  ///
  /// A batch, because the caller is a review run that finishes games one at a
  /// time — patching each on its own would re-read and rewrite the entire
  /// cache file once per game, which is quadratic in the size of the window
  /// for no gain. Games named here but absent from the file are skipped.
  static Future<int> patchGameMovetexts({
    required String cachePath,
    required Map<String, String> movetextByDedupKey,
    Map<String, String>? expectedPgnByDedupKey,
  }) async {
    if (movetextByDedupKey.isEmpty) return 0;
    final file = File(cachePath);
    if (!await file.exists()) return 0;
    var patched = 0;
    await updateTextFileAtomically(file, (current) {
      if (current == null) throw StateError('Games cache disappeared');
      final chunks = splitPgnIntoGames(current);
      final replacements = <String, String>{};
      for (var i = 0; i < chunks.length; i++) {
        final key = dedupKeyForHeaders(
          extractHeaders(chunks[i]),
          pgn: chunks[i],
        );
        final updatedMovetext = movetextByDedupKey[key];
        if (updatedMovetext == null) continue;
        final expected = expectedPgnByDedupKey?[key];
        if (expected != null && chunks[i].trim() != expected.trim()) {
          throw StateError(
            'This game was edited while analysis ran; annotations were not overwritten.',
          );
        }
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
        if (headerCount == 0) continue;
        final headers = lines.sublist(0, headerCount).join('\n');
        replacements[chunks[i]] = '$headers\n\n${updatedMovetext.trim()}';
        patched++;
      }
      if (patched == 0) return current;
      return patchPgnDocument(current, replacements);
    });
    return patched;
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
      // ECO + opening name headers, so a game card can say which opening it
      // was instead of making the reader parse the moves.
      'opening': 'true',
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
