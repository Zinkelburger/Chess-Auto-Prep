import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/games_library/game_filter.dart';
import '../../../services/games_library/game_review_store.dart';
import '../../../services/games_library/games_library_service.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/recent_game.dart';
import '../services/game_deviation_service.dart';
import '../services/game_moves.dart';
import '../services/game_preview.dart';
import '../services/game_review_summary.dart';
import '../services/games_window.dart';

/// Which speed buckets the games pane shows, and whether opening the app is
/// allowed to start the review run by itself. Persisted so the pane looks the
/// same every launch.
///
/// *How many* games it shows is not here: that is the app-wide
/// [GamesWindowSettings], shared with the tactics fetch.
class GamesListFilters {
  const GamesListFilters({
    this.speeds = const {
      GameSpeed.ultraBullet,
      GameSpeed.bullet,
      GameSpeed.blitz,
      GameSpeed.rapid,
      GameSpeed.classical,
    },
    this.autoRun = false,
  });

  final Set<GameSpeed> speeds;

  /// Whether the review run (analysis, deviations, mining) starts on its own
  /// when the list loads. Off by default — it is minutes of every core, and
  /// the user gets to decide when that happens by pressing Start.
  final bool autoRun;

  GamesListFilters copyWith({Set<GameSpeed>? speeds, bool? autoRun}) =>
      GamesListFilters(
        speeds: speeds ?? this.speeds,
        autoRun: autoRun ?? this.autoRun,
      );
}

/// State owner of the Games home page: loads recent games for the configured
/// default usernames through the shared games library, derives per-row view
/// models, then computes repertoire deviations for each.
class RecentGamesController extends ChangeNotifier with SafeChangeNotifier {
  RecentGamesController({
    required this._lichessUsername,
    required this._chesscomUsername,
    GamesLibraryService? library,
    GameDeviationService? deviationService,
    GamesWindowSettings? windowSettings,
    GameReviewStore? reviewStore,
    DateTime Function()? now,
  }) : _library = library ?? GamesLibraryService(),
       _deviation = deviationService ?? GameDeviationService.instance,
       _windowSettings = windowSettings ?? GamesWindowSettings.instance,
       _reviewStore = reviewStore ?? GameReviewStore.instance,
       _now = now ?? DateTime.now {
    // The engine pass files each game's counts in the store as it finishes, so
    // the rows fill in during a run without this controller knowing the review
    // is happening.
    _reviewStore.addListener(_applyStoredSummaries);
    // The window is edited on the accounts card, which writes straight through
    // to the shared setting. Without this the list kept its old slice until
    // something else reloaded it, while every label around it (they read the
    // setting live) already said "last 50 games" — the strip claiming
    // "Out of 20 in your last 50 games".
    _windowSettings.addListener(_onWindowChanged);
  }

  // Supplier callbacks, not cached values: the usernames live on AppState
  // and change when the user edits Settings → Accounts.
  final String? Function() _lichessUsername;
  final String? Function() _chesscomUsername;
  final GamesLibraryService _library;
  final GameDeviationService _deviation;

  /// The shared "which games" window (see [GamesWindowSettings]). Read through
  /// the settings object on every load, never snapshotted, so editing it in
  /// the tactics panel moves this list too.
  final GamesWindowSettings _windowSettings;

  /// Mistake counts the review's engine pass filed for each game.
  final GameReviewStore _reviewStore;

  /// Injectable clock so the window tests don't depend on wall time.
  final DateTime Function() _now;

  static const _speedsPrefsKey = 'recent_games.speeds';
  static const _autoRunPrefsKey = 'recent_games.auto_run';

  bool _loading = false;

  /// The load currently in flight, so a caller who arrives mid-load *waits for
  /// it* instead of being told there was nothing to do. Pressing Start while
  /// the first-visit load was still running used to return instantly and then
  /// review an empty list.
  Future<void>? _inFlight;
  bool _refreshQueued = false;
  bool _hasLoadedOnce = false;
  String? _statusMessage;
  String? _error;

  /// Every row the last load built: the union of the game-count slice *and*
  /// the day slice, whatever mode was active. [_games] is the active window's
  /// view of it — which is why flipping "last N games" ↔ "last N days" is a
  /// synchronous re-slice, not a reload (see [_onWindowChanged]).
  List<RecentGame> _allGames = const [];
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

  /// The accounts this list is loading. The header names the user even before
  /// the first game has arrived, so it cannot rely on the loaded games.
  List<String> get usernames => [
    for (final name in [_lichessUsername(), _chesscomUsername()])
      if (name != null && name.trim().isNotEmpty) name.trim(),
  ];

  /// The shared window this list is showing.
  GamesWindow get window => _windowSettings.window;

  /// Start of the window (counting today as day one), or null in game-count
  /// mode — there the cap, not a date, bounds the list.
  DateTime? get sinceCutoff => window.cutoffFrom(_now());

  /// First-visit load: fetch once usernames exist, and never re-trigger on
  /// later notifications. Safe to call from a listener on every tick.
  void ensureLoaded() {
    if (_hasLoadedOnce || _loading || !hasAnyUsername) return;
    unawaited(refresh());
  }

  /// Load the window's games. Concurrent callers share one load: the second
  /// caller gets the in-flight future rather than a no-op.
  Future<void> refresh({bool force = false}) =>
      _inFlight ??= _refresh(force: force).whenComplete(() => _inFlight = null);

  /// The window the loaded games were selected with, so a notification from
  /// [GamesWindowSettings] that changed nothing this list cares about (a
  /// re-save of the same value, or the first load resolving) doesn't refetch.
  GamesWindow? _loadedWindow;

  /// The window whose *operands* the rows in [_allGames] cover — both of
  /// them, since every load builds both slices. A new window inside these
  /// bounds is served from memory; a larger one needs a reload.
  GamesWindow? _builtWindow;

  /// True while [setFilters] is writing the window itself — it reloads once at
  /// the end, and the listener must not race it into a second fetch.
  bool _applyingWindow = false;

  void _onWindowChanged() {
    if (_applyingWindow || !_hasLoadedOnce) return;
    final next = _windowSettings.window;
    if (next == _loadedWindow) return;
    final built = _builtWindow;
    if (built != null && next.games <= built.games && next.days <= built.days) {
      // Both operands are within what the last load already built rows for,
      // so the toggle (or a shrink) is answered from memory: no fetch, no
      // cache re-parse, no isolate passes, no spinner.
      _loadedWindow = next;
      _games = _sliceForWindow(next);
      notifyListeners();
      return;
    }
    unawaited(refresh());
  }

  /// The active window's slice of [_allGames]. Mirrors [applySelection]'s
  /// semantics: the game cap counts per site, the day cutoff drops undated
  /// games, and order is preserved — [_allGames] is already newest-first.
  List<RecentGame> _sliceForWindow(GamesWindow window) {
    if (window.isGameCount) {
      final taken = <GamesPlatform, int>{};
      return [
        for (final g in _allGames)
          if ((taken[g.platform] = (taken[g.platform] ?? 0) + 1) <=
              window.games)
            g,
      ];
    }
    final cutoff = window.cutoffFrom(_now())!;
    return [
      for (final g in _allGames)
        if (g.record.date != null && !g.record.date!.isBefore(cutoff)) g,
    ];
  }

  Future<void> _refresh({bool force = false}) async {
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
      await _windowSettings.ensureLoaded();
      await _reviewStore.ensureLoaded();
      final buildWindow = window;
      _loadedWindow = buildWindow;
      // Both modes ride into one load: the active mode drives the network
      // fetch, and the other mode's slice is built from the same parse so a
      // later flip of the games/days toggle re-slices in memory instead of
      // re-running this whole pipeline. The game cap is per *site*, which is
      // what the label promises when only one account is configured — the
      // common case.
      final countSelection = GameSelection(
        maxGames: buildWindow.games,
        speeds: _filters.speeds,
      );
      final daySelection = GameSelection(
        since: buildWindow
            .copyWith(mode: GamesWindowMode.lastDays)
            .cutoffFrom(_now()),
        speeds: _filters.speeds,
      );
      final selection = buildWindow.isGameCount ? countSelection : daySelection;
      final otherSelection = buildWindow.isGameCount
          ? daySelection
          : countSelection;

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
            unionWith: [otherSelection],
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
          // Final positions for the row previews: a replay per game, off the
          // UI isolate like the other two passes.
          final finalFens = await compute(finalFensBatch, sansBatch);
          for (var i = 0; i < records.length; i++) {
            final record = records[i];
            collected.add(
              RecentGame(
                record: record,
                platform: platform,
                cachePath: cachePath,
                myUsername: username,
                meWhite: _sideFor(record, username),
                sans: sansBatch[i],
                finalFen: finalFens[i],
                // The review's own verdict wins over one derived from `[%eval]`
                // comments: it is the pass that classified these moves, and it
                // survives the evals being pruned from the cache.
              )..summary = _storedSummary(record.dedupKey) ?? summaries[i],
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

      _allGames = collected;
      _builtWindow = buildWindow;
      _games = _sliceForWindow(buildWindow);
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
      // of computing deviations nobody will see. Called directly, not through
      // [refresh]: that would hand back this very future and deadlock.
      _refreshQueued = false;
      return _refresh();
    }
    await _computeDeviations(epoch);
    // Checked again on the way out: the deviation pass is the long tail of a
    // load, and filters changed during it are just as stale-making as ones
    // changed during the fetch.
    if (_refreshQueued) {
      _refreshQueued = false;
      return _refresh();
    }
  }

  /// Re-run only the deviation pass (designations or repertoire files
  /// changed; the game list itself is still valid).
  Future<void> recomputeDeviations() async {
    _deviation.invalidateCache();
    for (final g in _allGames) {
      g.deviation = null;
      g.deviationComputed = false;
    }
    notifyListeners();
    await _computeDeviations(_refreshEpoch);
  }

  /// Flip only the auto-start preference. Unlike [setFilters] this does not
  /// reload: auto-run changes nothing about which games are listed, and the
  /// strip's checkbox should not cost a re-download.
  Future<void> setAutoRun(bool value) async {
    _filters = _filters.copyWith(autoRun: value);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoRunPrefsKey, value);
  }

  /// Apply new filters and (optionally) a new shared window, then reload.
  ///
  /// The window is set *before* the reload so a single Apply from the settings
  /// dialog produces one fetch with both changes, not two.
  Future<void> setFilters(
    GamesListFilters filters, {
    GamesWindow? window,
  }) async {
    _filters = filters;
    if (window != null) {
      _applyingWindow = true;
      try {
        await _windowSettings.set(window);
      } finally {
        _applyingWindow = false;
      }
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_speedsPrefsKey, [
      for (final s in filters.speeds) s.name,
    ]);
    await prefs.setBool(_autoRunPrefsKey, filters.autoRun);
    if (_inFlight != null) {
      // refresh() hands back the load already in flight, which would silently
      // drop the new filters; queue one — the running load chains into it.
      // Gated on the whole chain, not just `_loading`: that goes false before
      // the deviation pass, and new filters arriving in that gap used to be
      // swallowed by the in-flight future with no reload at all.
      _refreshQueued = true;
      return;
    }
    await refresh();
  }

  /// Runs over [_allGames], not the visible slice: the rows are shared, so
  /// a window flip finds its deviations already computed.
  Future<void> _computeDeviations(int epoch) async {
    final hasWhiteBook = await _deviation.hasRepertoireFor(white: true);
    final hasBlackBook = await _deviation.hasRepertoireFor(white: false);
    for (final game in _allGames) {
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

  /// The stored review verdict for one game, as the list's summary type.
  GameReviewSummary? _storedSummary(String dedupKey) {
    final counts = _reviewStore.countsFor(dedupKey);
    if (counts == null) return null;
    return GameReviewSummary(
      blunders: counts.blunders,
      mistakes: counts.mistakes,
      inaccuracies: counts.inaccuracies,
    );
  }

  /// A game finished its engine pass: adopt the counts for whichever loaded
  /// rows they belong to.
  void _applyStoredSummaries() {
    var changed = false;
    for (final game in _allGames) {
      final stored = _storedSummary(game.record.dedupKey);
      if (stored == null) continue;
      final current = game.summary;
      if (current != null &&
          current.blunders == stored.blunders &&
          current.mistakes == stored.mistakes &&
          current.inaccuracies == stored.inaccuracies) {
        continue;
      }
      game.summary = stored;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    _reviewStore.removeListener(_applyStoredSummaries);
    _windowSettings.removeListener(_onWindowChanged);
    super.dispose();
  }

  Future<void> _ensureFiltersLoaded() async {
    if (_filtersLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    final speedNames = prefs.getStringList(_speedsPrefsKey);
    final autoRun = prefs.getBool(_autoRunPrefsKey);
    if (speedNames != null || autoRun != null) {
      _filters = GamesListFilters(
        speeds: speedNames == null
            ? _filters.speeds
            : {
                for (final name in speedNames)
                  for (final s in GameSpeed.values)
                    if (s.name == name) s,
              },
        autoRun: autoRun ?? _filters.autoRun,
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
