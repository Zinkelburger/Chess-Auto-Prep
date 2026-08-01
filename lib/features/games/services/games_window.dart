/// The one "which of my games are we talking about" setting.
///
/// Three surfaces used to each carry their own copy of it — the recent-games
/// list (`sinceDays`), the tactics fetch form (`fetchMode` + count + days),
/// and the resume/prune cutoff — so changing "the last two weeks" in one place
/// left the other two on their old value. This is that setting, once:
/// either the last N games or the last N days, persisted, shared.
///
/// Deliberately *not* folded in here: how long a mined puzzle stays in the
/// training queue. That is a separate decision ("expire after"), lives on
/// [TacticsSessionSettings.maxAgeDays], and is edited next to the window in
/// the same dialog.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../utils/safe_change_notifier.dart';

/// Whether the window counts games or days.
enum GamesWindowMode {
  lastGames,
  lastDays;

  static GamesWindowMode fromStorage(String? value) =>
      GamesWindowMode.values.firstWhere(
        (m) => m.name == value,
        orElse: () => GamesWindowMode.lastGames,
      );
}

/// A resolved window: the mode plus *both* operands, so flipping the mode in
/// the UI never discards the number the user typed for the other one.
@immutable
class GamesWindow {
  const GamesWindow({
    this.mode = GamesWindowMode.lastGames,
    this.games = defaultGames,
    this.days = defaultDays,
  });

  /// A short list of recent games is what "how am I doing lately" actually
  /// means — a fortnight of blitz is hundreds of games nobody reviews.
  static const int defaultGames = 20;

  /// The day alternative is meant for "since I last sat down", not an
  /// archive, so it starts at two days rather than a fortnight.
  static const int defaultDays = 2;

  static const int maxGames = 1000;
  static const int maxDays = 3650;

  final GamesWindowMode mode;

  /// Games kept when [mode] is [GamesWindowMode.lastGames].
  final int games;

  /// Days kept when [mode] is [GamesWindowMode.lastDays], counting today as
  /// day one (so `1` = today, `2` = today and yesterday).
  final int days;

  bool get isGameCount => mode == GamesWindowMode.lastGames;

  /// Game cap for a fetch/selection, or null in day mode (there the day
  /// window is the only limit the user asked for).
  int? get gameLimit => isGameCount ? games : null;

  /// Start of the window, or null in game-count mode (no date bound at all).
  DateTime? cutoffFrom(DateTime now) {
    if (isGameCount) return null;
    return DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: days - 1));
  }

  /// "last 20 games" / "last 2 days" — used in labels, job names and empty
  /// states so every surface describes the window identically.
  String get label => isGameCount
      ? 'last $games ${games == 1 ? 'game' : 'games'}'
      : 'last $days ${days == 1 ? 'day' : 'days'}';

  GamesWindow copyWith({GamesWindowMode? mode, int? games, int? days}) =>
      GamesWindow(
        mode: mode ?? this.mode,
        games: (games ?? this.games).clamp(1, maxGames),
        days: (days ?? this.days).clamp(1, maxDays),
      );

  @override
  bool operator ==(Object other) =>
      other is GamesWindow &&
      other.mode == mode &&
      other.games == games &&
      other.days == days;

  @override
  int get hashCode => Object.hash(mode, games, days);

  @override
  String toString() => 'GamesWindow($label)';
}

/// Persisted, app-wide owner of the [GamesWindow]. Every surface that fetches
/// or filters "my recent games" reads this one instance, so the number the
/// user typed in the home dialog is the number the tactics fetch uses.
class GamesWindowSettings extends ChangeNotifier with SafeChangeNotifier {
  GamesWindowSettings._();

  static final GamesWindowSettings instance = GamesWindowSettings._();

  /// Test-only: an isolated instance that shares the same prefs keys.
  @visibleForTesting
  GamesWindowSettings.forTest();

  static const _keyMode = 'games_window.mode';
  static const _keyGames = 'games_window.games';
  static const _keyDays = 'games_window.days';

  GamesWindow _window = const GamesWindow();
  bool _loaded = false;
  Future<void>? _loading;

  GamesWindow get window => _window;
  bool get isLoaded => _loaded;

  /// Load once. Concurrent callers share the same in-flight future rather
  /// than racing two prefs reads (the home pane and the tactics panel both
  /// call this during the same startup frame).
  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _window = GamesWindow(
      mode: GamesWindowMode.fromStorage(prefs.getString(_keyMode)),
      games: prefs.getInt(_keyGames) ?? GamesWindow.defaultGames,
      days: prefs.getInt(_keyDays) ?? GamesWindow.defaultDays,
    );
    _loaded = true;
    _loading = null;
    notifyListeners();
  }

  Future<void> set(GamesWindow window) async {
    if (window == _window && _loaded) return;
    _window = window;
    _loaded = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyMode, window.mode.name);
    await prefs.setInt(_keyGames, window.games);
    await prefs.setInt(_keyDays, window.days);
  }
}
