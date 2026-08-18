/// Form state for the tactics import panel: text fields, debounced
/// validation, and the persisted depth preference.
///
/// Owned by the tactics control panel; extracted so the form logic is
/// testable and the panel only renders it.
///
/// Four things this form deliberately does *not* own, because each already has
/// exactly one owner elsewhere:
///
/// * **Whose games** — the usernames are `AppState`'s, edited on the accounts
///   card and in Settings → Accounts. This form used to keep text-controller
///   copies of both; nothing read them once the review pipeline switched to
///   supplier callbacks over `AppState`, and the card's fields now sync with
///   `AppState` directly.
/// * **Which games to fetch** — that is the app-wide [GamesWindowSettings],
///   shared with the recent-games home pane. Editing "last 20 games" here
///   moves the home list too, and vice versa; there is one such setting.
/// * **How many cores to use** — that is [EngineSettings.workers], the same
///   machine-level knob the Settings screen shows. Mining used to keep its
///   own copy, so turning it down in one place left the other at its old
///   value.
/// * **How deep to search** — that is [MiningSettings.depth], edited on the
///   review strip where its cost is felt. This form used to own it as a text
///   field behind a gear, which is how the two got out of step.
library;

import 'package:flutter/widgets.dart';

import '../../features/games/services/games_window.dart';
import '../../models/engine_settings.dart';
import '../../utils/safe_change_notifier.dart';
import 'mining_settings.dart';

class TacticsImportForm extends ChangeNotifier with SafeChangeNotifier {
  TacticsImportForm({
    EngineSettings? engine,
    GamesWindowSettings? windowSettings,
    MiningSettings? miningSettings,
  }) : _engine = engine ?? EngineSettings.instance,
       _windowSettings = windowSettings ?? GamesWindowSettings.instance,
       _mining = miningSettings ?? MiningSettings.instance {
    gamesText = TextEditingController(text: '${window.games}');
    daysText = TextEditingController(text: '${window.days}');
    _windowSettings.addListener(_onWindowChanged);
  }

  final EngineSettings _engine;
  final GamesWindowSettings _windowSettings;
  final MiningSettings _mining;

  /// Game-count and day operands of the shared window. Text controllers, not
  /// state: the value of record lives in [GamesWindowSettings].
  late final TextEditingController gamesText;
  late final TextEditingController daysText;

  /// The shared window (see [GamesWindowSettings]).
  GamesWindow get window => _windowSettings.window;

  /// Search depth — the shared [MiningSettings.depth], already clamped.
  int get depth => _mining.depth;

  /// Worker count — the shared [EngineSettings.workers], already clamped.
  int get cores => _engine.workers;

  /// Start of the window, or null when it counts games rather than days.
  DateTime? get sinceCutoff => window.cutoffFrom(DateTime.now());

  Future<void> setWindowMode(GamesWindowMode mode) =>
      _windowSettings.set(window.copyWith(mode: mode));

  Future<void> setWindowGames(int games) =>
      _windowSettings.set(window.copyWith(games: games));

  Future<void> setWindowDays(int days) =>
      _windowSettings.set(window.copyWith(days: days));

  /// Reflect an externally applied window (the home pane's settings dialog)
  /// into the fields, without fighting whichever one the user is typing in.
  void _onWindowChanged() {
    if (isDisposed) return;
    if (!_gamesFocused && int.tryParse(gamesText.text) != window.games) {
      gamesText.text = '${window.games}';
    }
    if (!_daysFocused && int.tryParse(daysText.text) != window.days) {
      daysText.text = '${window.days}';
    }
    notifyListeners();
  }

  /// Set by the panel while the corresponding field has focus (see
  /// [_onWindowChanged]).
  bool _gamesFocused = false;
  bool _daysFocused = false;
  void setGamesFieldFocused(bool focused) => _gamesFocused = focused;
  void setDaysFieldFocused(bool focused) => _daysFocused = focused;

  /// Load the settings this form displays. Each value belongs to its own
  /// owner; this only pulls them into the fields.
  Future<void> loadPrefs() async {
    await _windowSettings.ensureLoaded();
    await _mining.ensureLoaded();
    if (isDisposed) return;
    gamesText.text = '${window.games}';
    daysText.text = '${window.days}';
    notifyListeners();
  }

  @override
  void dispose() {
    _windowSettings.removeListener(_onWindowChanged);
    gamesText.dispose();
    daysText.dispose();
    super.dispose();
  }
}
