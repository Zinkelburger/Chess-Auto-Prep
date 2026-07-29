import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/games_library/game_filter.dart';
import '../../../services/games_library/games_library_service.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/recent_game.dart';
import '../services/game_deviation_service.dart';
import '../services/game_moves.dart';
import '../services/game_review_summary.dart';

/// Which speed buckets and how many games the games pane shows. Persisted so
/// the pane looks the same every launch.
class GamesListFilters {
  const GamesListFilters({
    this.speeds = const {
      GameSpeed.ultraBullet,
      GameSpeed.bullet,
      GameSpeed.blitz,
      GameSpeed.rapid,
      GameSpeed.classical,
    },
    this.maxGames = 100,
    this.sinceDays = 14,
    this.autoAnalyze = true,
  });

  final Set<GameSpeed> speeds;
  final int maxGames;

  /// Only show games from the last N days (counting today), mirroring the
  /// tactics fetch window. `0` = all time, same encoding tactics uses.
  final int sinceDays;

  /// Whether new games are analyzed automatically in the background so their
  /// review summaries appear without opening them.
  final bool autoAnalyze;
}

/// State owner of the Games home page: loads recent games for the configured
/// default usernames through the shared games library, derives per-row view
/// models, then computes repertoire deviations for each.
class RecentGamesController extends ChangeNotifier with SafeChangeNotifier {
  RecentGamesController({
    required String? Function() lichessUsername,
    required String? Function() chesscomUsername,
    GamesLibraryService? library,
    GameDeviationService? deviationService,
    DateTime Function()? now,
  }) : _lichessUsername = lichessUsername,
       _chesscomUsername = chesscomUsername,
       _library = library ?? GamesLibraryService(),
       _deviation = deviationService ?? GameDeviationService.instance,
       _now = now ?? DateTime.now;

  // Supplier callbacks, not cached values: the usernames live on AppState
  // and change when the user edits Settings → Accounts.
  final String? Function() _lichessUsername;
  final String? Function() _chesscomUsername;
  final GamesLibraryService _library;
  final GameDeviationService _deviation;

  /// Injectable clock so the expiry-window tests don't depend on wall time.
  final DateTime Function() _now;

  static const _speedsPrefsKey = 'recent_games.speeds';
  static const _maxGamesPrefsKey = 'recent_games.max';
  static const _sinceDaysPrefsKey = 'recent_games.since_days';
  static const _autoAnalyzePrefsKey = 'recent_games.auto_analyze';

  bool _loading = false;
  bool _refreshQueued = false;
  bool _hasLoadedOnce = false;
  String? _statusMessage;
  String? _error;
  List<RecentGame> _games = const [];
  GamesListFilters _filters = const GamesListFilters();
  bool _filtersLoaded = false;
  int _refreshEpoch = 0;

  bool get isLoading => _loading;
  bool get hasLoadedOnce => _hasLoadedOnce;
  String? get statusMessage => _statusMessage;
  String? get error => _error;
  List<RecentGame> get games => _games;
  GamesListFilters get filters => _filters;

  bool get hasAnyUsername =>
      (_chesscomUsername()?.trim().isNotEmpty ?? false) ||
      (_lichessUsername()?.trim().isNotEmpty ?? false);

  /// Start of the expiry window (mirrors tactics' `sinceCutoff`: counting
  /// today as day one), or null when the window is "all time".
  DateTime? get sinceCutoff {
    final days = _filters.sinceDays;
    if (days <= 0) return null;
    final today = _now();
    return DateTime(
      today.year,
      today.month,
      today.day,
    ).subtract(Duration(days: days - 1));
  }

  /// First-visit load: fetch once usernames exist, and never re-trigger on
  /// later notifications. Safe to call from a listener on every tick.
  void ensureLoaded() {
    if (_hasLoadedOnce || _loading || !hasAnyUsername) return;
    refresh();
  }

  Future<void> refresh({bool force = false}) async {
    if (_loading) return;
    final epoch = ++_refreshEpoch;
    _loading = true;
    _error = null;
    _statusMessage = null;
    notifyListeners();

    // try/finally around everything: `_loading` gates re-entry, so leaking it
    // on any throw (a prefs read, a decode) would wedge the page in "Loading
    // games…" with the refresh button disabled for the rest of the session.
    try {
      await _ensureFiltersLoaded();
      final selection = GameSelection(
        maxGames: _filters.maxGames,
        speeds: _filters.speeds,
        // The expiry window rides into the selection: it filters the cache
        // slice locally *and* narrows the network fetch to recent months.
        since: sinceCutoff,
      );

      final collected = <RecentGame>[];
      final errors = <String>[];
      final sources = <(GamesPlatform, String)>[
        if (_chesscomUsername()?.trim().isNotEmpty ?? false)
          (GamesPlatform.chesscom, _chesscomUsername()!.trim()),
        if (_lichessUsername()?.trim().isNotEmpty ?? false)
          (GamesPlatform.lichess, _lichessUsername()!.trim()),
      ];

      for (final (platform, username) in sources) {
        try {
          final records = await _library.getGames(
            platform: platform,
            username: username,
            selection: selection,
            forceRefresh: force,
            onProgress: (message) {
              if (epoch != _refreshEpoch) return;
              _statusMessage = message;
              notifyListeners();
            },
          );
          final cachePath = await _library.cacheFilePath(platform, username);
          final sansBatch = await compute(extractMainlineSansBatch, [
            for (final r in records) r.pgn,
          ]);
          final summaries = await compute(computeReviewSummariesBatch, [
            for (final r in records) (r.pgn, _sideFor(r, username)),
          ]);
          for (var i = 0; i < records.length; i++) {
            collected.add(
              RecentGame(
                record: records[i],
                platform: platform,
                cachePath: cachePath,
                myUsername: username,
                meWhite: _sideFor(records[i], username),
                sans: sansBatch[i],
              )..summary = summaries[i],
            );
          }
        } catch (e) {
          errors.add('${platform.name}: $e');
        }
      }
      if (epoch != _refreshEpoch) return;

      collected.sort((a, b) {
        final da = a.record.date, db = b.record.date;
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da);
      });

      _games = collected;
      _hasLoadedOnce = true;
      _statusMessage = null;
      _error = collected.isEmpty && errors.isNotEmpty
          ? errors.join('\n')
          : null;
    } catch (e) {
      if (epoch == _refreshEpoch) {
        _statusMessage = null;
        if (_games.isEmpty) _error = '$e';
      }
    } finally {
      if (epoch == _refreshEpoch) _loading = false;
    }
    notifyListeners();

    if (_refreshQueued) {
      // The filters changed while this load ran, so its result is already
      // stale — chain straight into a reload with the new selection instead
      // of computing deviations nobody will see.
      _refreshQueued = false;
      return refresh();
    }
    await _computeDeviations(epoch);
  }

  /// Re-run only the deviation pass (designations or repertoire files
  /// changed; the game list itself is still valid).
  Future<void> recomputeDeviations() async {
    _deviation.invalidateCache();
    for (final g in _games) {
      g.deviation = null;
      g.deviationComputed = false;
    }
    notifyListeners();
    await _computeDeviations(_refreshEpoch);
  }

  Future<void> setFilters(GamesListFilters filters) async {
    _filters = filters;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_speedsPrefsKey, [
      for (final s in filters.speeds) s.name,
    ]);
    await prefs.setInt(_maxGamesPrefsKey, filters.maxGames);
    await prefs.setInt(_sinceDaysPrefsKey, filters.sinceDays);
    await prefs.setBool(_autoAnalyzePrefsKey, filters.autoAnalyze);
    if (_loading) {
      // refresh() no-ops while a load is in flight, which would silently
      // drop the new filters; queue one — the running load chains into it.
      _refreshQueued = true;
      return;
    }
    await refresh();
  }

  Future<void> _computeDeviations(int epoch) async {
    final hasWhiteBook = await _deviation.hasRepertoireFor(white: true);
    final hasBlackBook = await _deviation.hasRepertoireFor(white: false);
    for (final game in _games) {
      if (epoch != _refreshEpoch) return;
      final meWhite = game.meWhite;
      if (meWhite == null) {
        game.deviationComputed = true;
        continue;
      }
      game.bookDesignated = meWhite ? hasWhiteBook : hasBlackBook;
      game.deviation = await _deviation.analyzeGame(
        gameSans: game.sans,
        meWhite: meWhite,
      );
      game.deviationComputed = true;
    }
    if (epoch != _refreshEpoch) return;
    notifyListeners();
  }

  Future<void> _ensureFiltersLoaded() async {
    if (_filtersLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    final speedNames = prefs.getStringList(_speedsPrefsKey);
    final maxGames = prefs.getInt(_maxGamesPrefsKey);
    final sinceDays = prefs.getInt(_sinceDaysPrefsKey);
    final autoAnalyze = prefs.getBool(_autoAnalyzePrefsKey);
    if (speedNames != null ||
        maxGames != null ||
        sinceDays != null ||
        autoAnalyze != null) {
      _filters = GamesListFilters(
        speeds: speedNames == null
            ? _filters.speeds
            : {
                for (final name in speedNames)
                  for (final s in GameSpeed.values)
                    if (s.name == name) s,
              },
        maxGames: maxGames ?? _filters.maxGames,
        sinceDays: sinceDays ?? _filters.sinceDays,
        autoAnalyze: autoAnalyze ?? _filters.autoAnalyze,
      );
    }
    _filtersLoaded = true;
  }

  static bool? _sideFor(GameRecord record, String username) {
    final u = username.toLowerCase();
    if (record.white.toLowerCase() == u) return true;
    if (record.black.toLowerCase() == u) return false;
    return null;
  }
}
