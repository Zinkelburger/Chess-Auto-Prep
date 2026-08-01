/// The shared games window: "my last 20 games" by default, "the last N days"
/// as the alternative, persisted once and read by every surface that asks
/// which games are recent. Replaces the old per-surface `sinceDays`.
library;

import 'package:chess_auto_prep/features/games/controllers/recent_games_controller.dart';
import 'package:chess_auto_prep/features/games/services/games_window.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingLibrary extends GamesLibraryService {
  final calls = <GameSelection>[];

  @override
  Future<List<GameRecord>> getGames({
    required GamesPlatform platform,
    required String username,
    GameSelection selection = const GameSelection(),
    bool forceRefresh = false,
    void Function(String message)? onProgress,
  }) async {
    calls.add(selection);
    return const [];
  }

  @override
  Future<String> cacheFilePath(GamesPlatform platform, String username) async =>
      '/tmp/${platform.name}_$username.pgn';
}

/// Let the event loop run until [done] holds — how many turns a reload needs
/// depends on the mocked prefs round-trips, so a fixed pump count is flaky
/// when test files run side by side.
Future<void> pumpUntil(bool Function() done, {int times = 500}) async {
  for (var i = 0; i < times && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GamesWindow', () {
    test('defaults to the last 20 games, with 2 days as the day operand', () {
      const window = GamesWindow();
      expect(window.mode, GamesWindowMode.lastGames);
      expect(window.games, 20);
      expect(window.days, 2);
      expect(window.label, 'last 20 games');
    });

    test('game-count mode bounds by count, never by date', () {
      const window = GamesWindow(games: 20);
      expect(window.gameLimit, 20);
      expect(window.cutoffFrom(DateTime(2026, 7, 29)), isNull);
    });

    test('day mode bounds by date, never by count, counting today as day '
        'one', () {
      const window = GamesWindow(mode: GamesWindowMode.lastDays, days: 2);
      expect(window.gameLimit, isNull);
      // Two days = today and yesterday, so one midnight back.
      expect(
        window.cutoffFrom(DateTime(2026, 7, 29, 15, 30)),
        DateTime(2026, 7, 28),
      );
      expect(window.label, 'last 2 days');
    });

    test('flipping the mode keeps both operands, so nothing typed is lost', () {
      const window = GamesWindow(games: 50, days: 9);
      final flipped = window.copyWith(mode: GamesWindowMode.lastDays);
      expect(flipped.games, 50);
      expect(flipped.days, 9);
      expect(flipped.copyWith(mode: GamesWindowMode.lastGames), window);
    });

    test('copyWith clamps out-of-range operands', () {
      expect(const GamesWindow().copyWith(games: 0).games, 1);
      expect(const GamesWindow().copyWith(days: -5).days, 1);
      expect(
        const GamesWindow().copyWith(games: 99999).games,
        GamesWindow.maxGames,
      );
    });
  });

  group('GamesWindowSettings', () {
    test('persists and reloads the whole window', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = GamesWindowSettings.forTest();
      await settings.ensureLoaded();
      expect(settings.window, const GamesWindow());

      await settings.set(
        const GamesWindow(mode: GamesWindowMode.lastDays, games: 40, days: 5),
      );

      final reloaded = GamesWindowSettings.forTest();
      await reloaded.ensureLoaded();
      expect(reloaded.window.mode, GamesWindowMode.lastDays);
      expect(reloaded.window.games, 40);
      expect(reloaded.window.days, 5);
    });

    test('concurrent ensureLoaded calls share one read', () async {
      SharedPreferences.setMockInitialValues({'games_window.games': 33});
      final settings = GamesWindowSettings.forTest();
      await Future.wait([settings.ensureLoaded(), settings.ensureLoaded()]);
      expect(settings.window.games, 33);
    });
  });

  group('RecentGamesController reads the shared window', () {
    RecentGamesController build(
      _RecordingLibrary library,
      GamesWindowSettings window,
    ) => RecentGamesController(
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      library: library,
      windowSettings: window,
      now: () => DateTime(2026, 7, 29, 15, 30),
    );

    test('the default window caps the fetch at 20 games and sets no '
        'cutoff', () async {
      SharedPreferences.setMockInitialValues({});
      final library = _RecordingLibrary();
      final controller = build(library, GamesWindowSettings.forTest());
      addTearDown(controller.dispose);

      await controller.refresh();

      expect(library.calls.single.maxGames, 20);
      expect(library.calls.single.since, isNull);
      expect(controller.sinceCutoff, isNull);
    });

    test('day mode sends the cutoff and no game cap', () async {
      SharedPreferences.setMockInitialValues({});
      final library = _RecordingLibrary();
      final window = GamesWindowSettings.forTest();
      final controller = build(library, window);
      addTearDown(controller.dispose);

      await controller.setFilters(
        const GamesListFilters(),
        window: const GamesWindow(mode: GamesWindowMode.lastDays, days: 2),
      );

      expect(controller.sinceCutoff, DateTime(2026, 7, 28));
      expect(library.calls.last.since, DateTime(2026, 7, 28));
      expect(library.calls.last.maxGames, isNull);
      expect(window.window.days, 2, reason: 'written through to the setting');
    });

    test('a window edited elsewhere reloads the list', () async {
      SharedPreferences.setMockInitialValues({});
      final library = _RecordingLibrary();
      final window = GamesWindowSettings.forTest();
      final controller = build(library, window);
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(library.calls, hasLength(1));

      // What the accounts card does: write straight through to the shared
      // setting. Without the controller listening, the list kept its old
      // slice while every label around it already read the new window.
      await window.set(const GamesWindow(games: 50));
      await pumpUntil(() => library.calls.length > 1);

      expect(library.calls, hasLength(2));
      expect(library.calls.last.maxGames, 50);
    });

    test('setFilters applies the window in one reload, not two', () async {
      SharedPreferences.setMockInitialValues({});
      final library = _RecordingLibrary();
      final window = GamesWindowSettings.forTest();
      final controller = build(library, window);
      addTearDown(controller.dispose);

      await controller.refresh();
      await controller.setFilters(
        const GamesListFilters(),
        window: const GamesWindow(mode: GamesWindowMode.lastDays, days: 3),
      );
      // Generous, and deliberately not condition-based: the point is that no
      // *third* fetch turns up once everything has settled.
      await pumpEventQueue(times: 200);

      // The write notifies the same listener the accounts card goes through,
      // so setFilters must not fetch a second time on top of it.
      expect(library.calls, hasLength(2));
      expect(library.calls.last.since, DateTime(2026, 7, 27));
    });

    test('auto-run is off by default and persists when turned on', () async {
      SharedPreferences.setMockInitialValues({});
      final library = _RecordingLibrary();
      final controller = build(library, GamesWindowSettings.forTest());
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.filters.autoRun, isFalse);

      await controller.setFilters(const GamesListFilters(autoRun: true));

      final reloaded = build(
        _RecordingLibrary(),
        GamesWindowSettings.forTest(),
      );
      addTearDown(reloaded.dispose);
      await reloaded.refresh();
      expect(reloaded.filters.autoRun, isTrue);
    });
  });
}
