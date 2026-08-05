/// The Games page loader's failure handling: a throwing load must not leave
/// the page stuck in its loading state, because `_loading` also gates re-entry
/// — a leaked flag disables the refresh button for the rest of the session.
library;

import 'dart:async';

import 'package:chess_auto_prep/features/games/controllers/recent_games_controller.dart';
import 'package:chess_auto_prep/features/games/services/games_window.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A library whose fetch always blows up, standing in for an unreachable API.
class _ThrowingLibrary extends GamesLibraryService {
  int calls = 0;

  @override
  Future<List<GameRecord>> getGames({
    required GamesPlatform platform,
    required String username,
    GameSelection selection = const GameSelection(),
    List<GameSelection> unionWith = const [],
    bool forceRefresh = false,
    void Function(String message)? onProgress,
  }) async {
    calls++;
    throw StateError('network down');
  }
}

/// A library whose fetch blocks on [gate], so a test can hold a load
/// in flight; records the selection of every call.
class _GatedLibrary extends GamesLibraryService {
  final calls = <GameSelection>[];
  final gate = Completer<List<GameRecord>>();

  @override
  Future<List<GameRecord>> getGames({
    required GamesPlatform platform,
    required String username,
    GameSelection selection = const GameSelection(),
    List<GameSelection> unionWith = const [],
    bool forceRefresh = false,
    void Function(String message)? onProgress,
  }) {
    calls.add(selection);
    return gate.future;
  }

  // The real one resolves an app-support directory, which unit tests lack.
  @override
  Future<String> cacheFilePath(GamesPlatform platform, String username) async =>
      '/tmp/${platform.name}_$username.pgn';
}

/// Serves slices of a fixed PGN through the real pure filter logic, so union
/// behaviour matches production; counts how many loads actually ran.
class _PgnLibrary extends GamesLibraryService {
  _PgnLibrary(this.pgn);

  final String pgn;
  int loads = 0;

  @override
  Future<List<GameRecord>> getGames({
    required GamesPlatform platform,
    required String username,
    GameSelection selection = const GameSelection(),
    List<GameSelection> unionWith = const [],
    bool forceRefresh = false,
    void Function(String message)? onProgress,
  }) async {
    loads++;
    return GamesLibraryService.selectFromPgnUnion(pgn, [
      selection,
      ...unionWith,
    ]);
  }

  @override
  Future<String> cacheFilePath(GamesPlatform platform, String username) async =>
      '/tmp/${platform.name}_$username.pgn';
}

String _game({required String white, required String date, String? time}) =>
    '[Event "Rated blitz game"]\n'
    '[Site "https://lichess.org/$white"]\n'
    '[White "$white"]\n'
    '[Black "opp"]\n'
    '[UTCDate "$date"]\n'
    '${time != null ? '[UTCTime "$time"]\n' : ''}'
    '[TimeControl "300+0"]\n'
    '[Result "1-0"]\n'
    '\n'
    '1. e4 e5 1-0';

/// Three dated games: today, yesterday, three days back (relative to the
/// injected clock below).
final _threeGames = [
  _game(white: 'w1', date: '2026.08.04', time: '10:00:00'),
  _game(white: 'w2', date: '2026.08.03', time: '22:00:00'),
  _game(white: 'w3', date: '2026.08.01', time: '09:00:00'),
].join('\n\n');

Future<void> _pumpUntil(bool Function() done, {int times = 500}) async {
  for (var i = 0; i < times && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'flipping the window mode re-slices in memory, without a reload',
    () async {
      SharedPreferences.setMockInitialValues({});
      final windowSettings = GamesWindowSettings.forTest();
      await windowSettings.set(
        const GamesWindow(mode: GamesWindowMode.lastGames, games: 1, days: 2),
      );
      final library = _PgnLibrary(_threeGames);
      final controller = RecentGamesController(
        lichessUsername: () => 'me',
        chesscomUsername: () => null,
        library: library,
        windowSettings: windowSettings,
        now: () => DateTime(2026, 8, 4, 12),
      );
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(library.loads, 1);
      expect([for (final g in controller.games) g.white], ['w1']);

      // games ↔ days both stay inside what that one load built, so the toggle
      // is instant: no further library call, just a different slice.
      await windowSettings.set(
        windowSettings.window.copyWith(mode: GamesWindowMode.lastDays),
      );
      expect(library.loads, 1, reason: 'the day slice was built by the load');
      expect([for (final g in controller.games) g.white], ['w1', 'w2']);

      await windowSettings.set(
        windowSettings.window.copyWith(mode: GamesWindowMode.lastGames),
      );
      expect(library.loads, 1);
      expect([for (final g in controller.games) g.white], ['w1']);
    },
  );

  test('growing the window past what was built reloads', () async {
    SharedPreferences.setMockInitialValues({});
    final windowSettings = GamesWindowSettings.forTest();
    await windowSettings.set(
      const GamesWindow(mode: GamesWindowMode.lastGames, games: 1, days: 2),
    );
    final library = _PgnLibrary(_threeGames);
    final controller = RecentGamesController(
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      library: library,
      windowSettings: windowSettings,
      now: () => DateTime(2026, 8, 4, 12),
    );
    addTearDown(controller.dispose);

    await controller.refresh();
    expect(library.loads, 1);

    await windowSettings.set(windowSettings.window.copyWith(games: 5));
    await _pumpUntil(() => controller.games.length == 3);
    expect(library.loads, 2, reason: 'a larger cap needs rows not yet built');
    expect([for (final g in controller.games) g.white], ['w1', 'w2', 'w3']);
  });

  test('a refresh that throws outside the per-source guard still releases '
      'isLoading', () async {
    // A corrupted saved filter: getStringList on a non-list throws, and the
    // prefs read happens before the per-source try. This is the path that
    // used to escape refresh() and strand `_loading` at true forever.
    SharedPreferences.setMockInitialValues({'recent_games.speeds': 42});

    final library = _ThrowingLibrary();
    final controller = RecentGamesController(
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      library: library,
      windowSettings: GamesWindowSettings.forTest(),
    );
    addTearDown(controller.dispose);

    await controller.refresh();

    expect(controller.isLoading, isFalse, reason: 'the flag must be released');
    expect(controller.error, isNotNull, reason: 'the failure is surfaced');
  });

  test('a failing fetch clears isLoading and stays retryable', () async {
    SharedPreferences.setMockInitialValues({});

    final library = _ThrowingLibrary();
    final controller = RecentGamesController(
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      library: library,
      windowSettings: GamesWindowSettings.forTest(),
    );
    addTearDown(controller.dispose);

    await controller.refresh();

    expect(controller.isLoading, isFalse);
    expect(controller.error, isNotNull);
    expect(controller.games, isEmpty);

    // The point of clearing the flag: a second attempt actually runs.
    await controller.refresh(force: true);
    expect(library.calls, 2);
    expect(controller.isLoading, isFalse);
  });

  test('filters applied during an in-flight load queue a reload with the '
      'new selection instead of being dropped', () async {
    SharedPreferences.setMockInitialValues({});

    final library = _GatedLibrary();
    final controller = RecentGamesController(
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      library: library,
      windowSettings: GamesWindowSettings.forTest(),
    );
    addTearDown(controller.dispose);

    final firstLoad = controller.refresh();
    while (library.calls.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.isLoading, isTrue);

    // refresh() no-ops while loading, so without queueing these filters
    // would be persisted but never applied to the visible list.
    await controller.setFilters(
      const GamesListFilters(speeds: {GameSpeed.blitz}),
      window: const GamesWindow(games: 5),
    );
    expect(library.calls, hasLength(1), reason: 'reload waits for the load');

    library.gate.complete(const []);
    await firstLoad;

    expect(library.calls, hasLength(2), reason: 'the queued reload ran');
    expect(library.calls.last.maxGames, 5);
    expect(library.calls.last.speeds, {GameSpeed.blitz});
    expect(controller.isLoading, isFalse);
  });
}
