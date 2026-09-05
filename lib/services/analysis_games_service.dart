import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'dart:io';
import 'dart:convert';

import '../models/analysis_player_info.dart';
import 'chess_api_urls.dart';
import 'lichess_api_client.dart';
import 'pgn_parsing_service.dart';
import '../utils/atomic_file.dart';
import 'storage/app_paths.dart';
import 'storage/storage_factory.dart';
import 'analysis/player_corpus_store.dart';
import 'games_library/game_filter.dart';

/// Service for downloading and managing games for position analysis.
///
/// Maintains a separate on-disk store from the imported games used for tactics.
/// Each player has an opaque identity directory. An atomic manifest selects a
/// retained generation containing its PGN, metadata and derived caches.
/// Legacy flat files are retained during migration; SQLite is a derived index.
class AnalysisGamesService {
  final PlayerCorpusStore _corpora = PlayerCorpusStore();
  String? storageWarning;

  // ── Downloads ──────────────────────────────────────────────────────

  /// Fetch the list of monthly archive URLs from Chess.com.
  ///
  /// Returns the URLs in chronological order (oldest first), or an empty
  /// list if the player has no archives.
  Future<List<String>> _fetchChesscomArchives(String username) async {
    final url = chesscomArchivesUrl(username);
    final response = await http.get(url);
    if (response.statusCode != 200) return [];
    final data = json.decode(response.body) as Map<String, dynamic>;
    return List<String>.from(data['archives'] as List);
  }

  /// Download games from Chess.com, keeping only the time controls in
  /// [speeds] (by default everything but bullet).
  ///
  /// Uses the Chess.com archives endpoint to discover which months actually
  /// have games, avoiding wasted requests to empty months and reliably
  /// finding games for inactive players.
  ///
  /// Two modes controlled by [monthsBack]:
  ///   • `null` (game-count mode) – walk backwards through every available
  ///     archive, stop at [maxGames] kept games.
  ///   • non-null (months mode) – fetch only archives that fall within the
  ///     last [monthsBack] calendar months.
  Future<String> downloadChesscomGames(
    String username, {
    int maxGames = 100,
    int? monthsBack,
    Set<GameSpeed> speeds = defaultDownloadSpeeds,
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
            if (keepsGameSpeed(game, speeds)) allGames.add(game);
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

  /// Download games from Lichess, asking the API for only the time controls
  /// in [speeds] (by default everything but bullet). The filter is the
  /// server's, so the request also drops variants — crazyhouse and friends
  /// have their own perf types.
  ///
  /// Two modes controlled by [monthsBack]:
  ///   • `null` (game-count mode) – uses the `max` API parameter.
  ///   • non-null (months mode) – uses the `since` API parameter with a
  ///     timestamp [monthsBack] months in the past.
  Future<String> downloadLichessGames(
    String username, {
    int maxGames = 100,
    int? monthsBack,
    Set<GameSpeed> speeds = defaultDownloadSpeeds,
    void Function(String)? onProgress,
  }) async {
    onProgress?.call('Downloading games from Lichess…');

    final params = <String, String>{
      'perfType': lichessPerfTypes(speeds),
      'moves': 'true',
      'tags': 'true',
      // Clocks feed the tempo flaw tags when these PGNs are re-mined.
      'clocks': 'true',
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

    final uri = lichessUserGamesUrl(username, params);

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

  /// Download games for one account on either platform.
  Future<String> downloadAccountGames(
    PlayerAccount account, {
    int maxGames = 100,
    int? monthsBack,
    Set<GameSpeed> speeds = defaultDownloadSpeeds,
    void Function(String)? onProgress,
  }) {
    return account.platform == 'lichess'
        ? downloadLichessGames(
            account.username,
            maxGames: maxGames,
            monthsBack: monthsBack,
            speeds: speeds,
            onProgress: onProgress,
          )
        : downloadChesscomGames(
            account.username,
            maxGames: maxGames,
            monthsBack: monthsBack,
            speeds: speeds,
            onProgress: onProgress,
          );
  }

  /// Download (or re-download) everything [player] is sourced from: the one
  /// live account for a plain download, or every account of an opponent
  /// built from an opponent list, concatenated into one PGN. Throws
  /// [StateError] for a PGN-file import, which has no source.
  ///
  /// [maxGames] applies per account, so a two-account opponent may return up
  /// to twice as many games — the cap is about API cost, not corpus size.
  /// The time controls come from the player itself ([AnalysisPlayerInfo.speeds]).
  Future<String> downloadGamesFor(
    AnalysisPlayerInfo player, {
    int? maxGames,
    int? monthsBack,
    void Function(String)? onProgress,
  }) async {
    if (!player.canRedownload) {
      throw StateError('${player.username} has no source to download from.');
    }
    final accounts = player.accounts.isNotEmpty
        ? player.accounts
        : [PlayerAccount(player.platform, player.username)];

    final parts = <String>[];
    for (final account in accounts) {
      final prefix = accounts.length > 1 ? '${account.username}: ' : '';
      final pgns = await downloadAccountGames(
        account,
        maxGames: maxGames ?? player.maxGames,
        monthsBack: monthsBack,
        speeds: player.speeds,
        onProgress: (m) => onProgress?.call('$prefix$m'),
      );
      if (pgns.trim().isNotEmpty) parts.add(pgns.trim());
    }
    return parts.join('\n\n');
  }

  // ── Persistence ────────────────────────────────────────────────────

  /// Publish a complete generation with one manifest switch. Earlier versions
  /// stay on disk; search indexing is versioned and retried separately.
  Future<AnalysisPlayerInfo> saveAnalysisGames(
    String pgns, {
    required String platform,
    required String username,
    required int maxGames,
    int? monthsBack,
    Set<GameSpeed> speeds = defaultDownloadSpeeds,
    List<PlayerAccount> accounts = const [],
    String? group,
  }) async {
    final info = AnalysisPlayerInfo(
      platform: platform,
      username: username,
      maxGames: maxGames,
      monthsBack: monthsBack,
      speeds: speeds,
      accounts: accounts,
      group: group,
      downloadedAt: DateTime.now(),
      gameCount: countPgnGames(pgns),
    );
    final saved = await _corpora.save(info, pgns);
    storageWarning = saved.info.storageWarning;
    return saved.info;
  }

  Future<AnalysisPlayerInfo?> findExistingPlayer(
    String platform,
    String username,
  ) async => (await _corpora.load(platform, username, reconcile: false))?.info;

  Future<List<AnalysisPlayerInfo>> getAllCachedPlayers() => _corpora.list();

  Future<String?> loadAnalysisGames(String platform, String username) async {
    final corpus = await _corpora.load(platform, username);
    storageWarning = corpus?.info.storageWarning;
    return corpus == null ? null : readTextFileSafely(File(corpus.pgnPath));
  }

  Future<String> analysisPgnPath(String platform, String username) async {
    final corpus = await _corpora.load(platform, username);
    storageWarning = corpus?.info.storageWarning;
    if (corpus != null) return corpus.pgnPath;
    final root = await AppPaths.analysisGamesDirectory();
    return p.join(
      root.path,
      AnalysisPlayerInfo(platform: platform, username: username).playerKey,
      'missing.pgn',
    );
  }

  Future<PlayerCorpus?> loadCorpus(String platform, String username) =>
      _corpora.load(platform, username);

  Future<String> corpusFingerprint(String platform, String username) async =>
      (await _corpora.load(platform, username))?.fingerprint ?? '';

  Future<String> _cachePath(
    String platform,
    String username,
    String name,
  ) async {
    final corpus = await _corpora.load(platform, username, reconcile: true);
    if (corpus != null) return corpus.cachePath(name);
    final root = await AppPaths.analysisGamesDirectory();
    return p.join(
      root.path,
      AnalysisPlayerInfo(platform: platform, username: username).playerKey,
      'unpublished',
      name,
    );
  }

  Future<String> cachedAnalysisPath(
    String platform,
    String username,
    bool isWhite,
  ) => _cachePath(
    platform,
    username,
    '${isWhite ? 'white' : 'black'}_analysis.json',
  );
  Future<String> holesReportPath(
    String platform,
    String username,
    bool isWhite,
  ) => _cachePath(
    platform,
    username,
    'holes_${isWhite ? 'white' : 'black'}.json',
  );
  Future<String> tricksReportPath(
    String platform,
    String username,
    bool isWhite,
  ) => _cachePath(
    platform,
    username,
    'tricks_${isWhite ? 'white' : 'black'}.json',
  );

  Future<void> deletePlayerData(String platform, String username) =>
      _corpora.tombstone(platform, username);

  Future<void> clearCachedAnalysis(String platform, String username) async {
    final corpus = await _corpora.load(platform, username, reconcile: false);
    if (corpus == null) return;
    for (final name in [
      'white_analysis.json',
      'black_analysis.json',
      'holes_white.json',
      'holes_black.json',
      'tricks_white.json',
      'tricks_black.json',
      'engine_evals.json',
    ]) {
      await StorageFactory.instance.deleteFile(corpus.cachePath(name));
    }
  }

  Future<void> saveEngineEvals(
    String platform,
    String username,
    List<Map<String, dynamic>> evals, {
    String? expectedFingerprint,
  }) async {
    final corpus = await _corpora.load(platform, username);
    if (corpus == null) throw StateError('Player games are not available.');
    if (expectedFingerprint != null &&
        corpus.fingerprint != expectedFingerprint) {
      throw StateError(
        'Player games changed while analysis ran. These results were not saved over the new corpus.',
      );
    }
    await writeTextFileAtomically(
      File(corpus.cachePath('engine_evals.json')),
      jsonEncode({
        'version': 1,
        'fingerprint': corpus.fingerprint,
        'evals': evals,
      }),
    );
  }

  Future<List<dynamic>?> loadEngineEvals(
    String platform,
    String username,
  ) async {
    final corpus = await _corpora.load(platform, username);
    if (corpus == null) return null;
    final raw = await readTextFileSafely(
      File(corpus.cachePath('engine_evals.json')),
    );
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map ||
          data['version'] != 1 ||
          data['fingerprint'] != corpus.fingerprint) {
        return null;
      }
      return data['evals'] as List<dynamic>;
    } on FormatException {
      return null;
    }
  }
}

// ── Utilities ────────────────────────────────────────────────────────

/// Whether one game's TimeControl header falls in [speeds]. A game with no
/// header at all is kept: a filter should never throw away what it cannot
/// read, and Chess.com's Daily games are the usual case.
bool keepsGameSpeed(String pgn, Set<GameSpeed> speeds) {
  final match = RegExp(r'\[TimeControl "([^"]*)"\]').firstMatch(pgn);
  final speed = classifySpeed(match?.group(1));
  return speed == GameSpeed.unknown || speeds.contains(speed);
}

/// The `perfType` value the Lichess games export takes for [speeds], in the
/// API's own spelling and order.
String lichessPerfTypes(Set<GameSpeed> speeds) => [
  for (final s in selectableGameSpeeds)
    if (speeds.contains(s)) s.lichessPerfType!,
].join(',');
