/// The Games page loader's failure handling: a throwing load must not leave
/// the page stuck in its loading state, because `_loading` also gates re-entry
/// — a leaked flag disables the refresh button for the rest of the session.
library;

import 'dart:async';

import 'package:chess_auto_prep/features/games/controllers/recent_games_controller.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      const GamesListFilters(speeds: {GameSpeed.blitz}, maxGames: 5),
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
