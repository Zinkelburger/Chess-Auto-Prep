import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models/analysis_player_info.dart';
import '../utils/atomic_file.dart';
import 'analysis/player_corpus_store.dart';
import 'chess_api_urls.dart';
import 'games_library/game_filter.dart';
import 'lichess_api_client.dart';
import '../chess_core/pgn/pgn_text.dart';
import 'storage/app_paths.dart';
import 'storage/storage_factory.dart';

/// Service for downloading and managing games for position analysis.
///
/// Maintains a separate on-disk store from the imported games used for tactics.
/// Each player has an opaque identity directory. An atomic manifest selects a
/// retained generation containing its PGN, metadata and derived caches.
/// Legacy flat files are retained during migration; SQLite is a derived index.
class AnalysisGamesService {
  /// Gap between Chess.com archive requests, to be polite to the API.
  static const Duration _chesscomRequestGap = Duration(milliseconds: 300);

  /// Derived caches kept next to a player's PGN.
  static const String _engineEvalsFile = 'engine_evals.json';
  static const List<String> _derivedCacheFiles = [
    'white_analysis.json',
    'black_analysis.json',
    'holes_white.json',
    'holes_black.json',
    'tricks_white.json',
    'tricks_black.json',
    _engineEvalsFile,
  ];

  /// Layout version of [_engineEvalsFile]; a file with another version or
  /// another corpus fingerprint is ignored.
  static const int _engineEvalsVersion = 1;

  final PlayerCorpusStore _corpora = PlayerCorpusStore();
  String? storageWarning;

  // ── Downloads ──────────────────────────────────────────────────────

  /// Fetch the list of monthly archive URLs from Chess.com.
  ///
  /// Returns the URLs in chronological order (oldest first), or an empty
  /// list if the player has no archives.
  Future<List<String>> _fetchChesscomArchives(String username) async {
    final response = await http.get(chesscomArchivesUrl(username));
    if (response.statusCode != 200) return [];
    final data = json.decode(response.body) as Map<String, dynamic>;
    return (data['archives'] as List).cast<String>();
  }

  /// The month a Chess.com archive URL (`.../games/YYYY/MM`) covers, or null
  /// when the URL does not end that way.
  static DateTime? _archiveMonth(String archiveUrl) {
    final parts = archiveUrl.split('/');
    if (parts.length < 2) return null;
    final year = int.tryParse(parts[parts.length - 2]);
    final month = int.tryParse(parts[parts.length - 1]);
    if (year == null || month == null) return null;
    return DateTime(year, month);
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

    final allGames = <String>[];

    // In months mode, the earliest archive month still wanted.
    // E.g. monthsBack=6 and now=2026-02 → cutoff = 2025-09.
    final now = DateTime.now();
    final cutoff = monthsBack == null
        ? null
        : DateTime(now.year, now.month - monthsBack + 1);
    final isDateMode = cutoff != null;
    bool haveEnough() => !isDateMode && allGames.length >= maxGames;

    // Walk backwards from the most recent archive.
    for (final archive in archives.reversed) {
      if (haveEnough()) break;

      // In months mode, stop at the first archive before the cutoff.
      if (cutoff != null) {
        final month = _archiveMonth(archive);
        if (month != null && month.isBefore(cutoff)) break;
      }

      onProgress?.call(
        isDateMode
            ? '${allGames.length} games downloaded so far…'
            : '${allGames.length} / $maxGames games downloaded so far…',
      );

      try {
        final response = await http.get(Uri.parse('$archive/pgn'));
        if (response.statusCode == 200 && response.body.isNotEmpty) {
          for (final game in splitPgnIntoGames(stripBom(response.body))) {
            if (haveEnough()) break;
            if (keepsGameSpeed(game, speeds)) allGames.add(game);
          }
        }
      } catch (e) {
        onProgress?.call('Error fetching archive: $e');
      }

      await Future<void>.delayed(_chesscomRequestGap);
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
      // The API takes a timestamp, so a month is 30 days here; the
      // Chess.com path can only stop at whole archive months.
      final since = DateTime.now().subtract(Duration(days: monthsBack * 30));
      params['since'] = since.millisecondsSinceEpoch.toString();
    } else {
      params['max'] = maxGames.toString();
    }

    final response = await LichessApiClient.instance.get(
      lichessUserGamesUrl(username, params),
      extraHeaders: const {'Accept': 'application/x-chess-pgn'},
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
  ) => _cachePath(platform, username, '${_colorName(isWhite)}_analysis.json');

  Future<String> holesReportPath(
    String platform,
    String username,
    bool isWhite,
  ) => _cachePath(platform, username, 'holes_${_colorName(isWhite)}.json');

  static String _colorName(bool isWhite) => isWhite ? 'white' : 'black';

  Future<void> deletePlayerData(String platform, String username) =>
      _corpora.tombstone(platform, username);

  Future<void> clearCachedAnalysis(String platform, String username) async {
    final corpus = await _corpora.load(platform, username, reconcile: false);
    if (corpus == null) return;
    for (final name in _derivedCacheFiles) {
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
      File(corpus.cachePath(_engineEvalsFile)),
      jsonEncode({
        'version': _engineEvalsVersion,
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
      File(corpus.cachePath(_engineEvalsFile)),
    );
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map ||
          data['version'] != _engineEvalsVersion ||
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
  final speed = classifySpeed(_timeControlHeader.firstMatch(pgn)?.group(1));
  return speed == GameSpeed.unknown || speeds.contains(speed);
}

final RegExp _timeControlHeader = RegExp(r'\[TimeControl "([^"]*)"\]');

/// The `perfType` value the Lichess games export takes for [speeds], in the
/// API's own spelling and order.
String lichessPerfTypes(Set<GameSpeed> speeds) => [
  for (final s in selectableGameSpeeds)
    if (speeds.contains(s)) s.lichessPerfType!,
].join(',');
