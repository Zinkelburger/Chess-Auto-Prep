/// The recent-games expiry window: 14 days by default (counting today, same
/// arithmetic as the tactics fetch window), rides into the [GameSelection] so
/// it narrows both the cache slice and the network fetch, and 0 disables it.
library;

import 'dart:async';

import 'package:chess_auto_prep/features/games/controllers/recent_games_controller.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  RecentGamesController build(_RecordingLibrary library) =>
      RecentGamesController(
        lichessUsername: () => 'me',
        chesscomUsername: () => null,
        library: library,
        now: () => DateTime(2026, 7, 29, 15, 30),
      );

  test('default window is 14 days counting today', () async {
    SharedPreferences.setMockInitialValues({});
    final library = _RecordingLibrary();
    final controller = build(library);
    addTearDown(controller.dispose);

    expect(controller.sinceCutoff, DateTime(2026, 7, 16));

    await controller.refresh();
    expect(library.calls.single.since, DateTime(2026, 7, 16));
  });

  test('0 means all time: no since filter at all', () async {
    SharedPreferences.setMockInitialValues({});
    final library = _RecordingLibrary();
    final controller = build(library);
    addTearDown(controller.dispose);

    await controller.setFilters(const GamesListFilters(sinceDays: 0));
    expect(controller.sinceCutoff, isNull);
    expect(library.calls.last.since, isNull);
  });

  test('the window persists like the other filters', () async {
    SharedPreferences.setMockInitialValues({});
    final library = _RecordingLibrary();
    final controller = build(library);
    addTearDown(controller.dispose);
    await controller.setFilters(
      const GamesListFilters(sinceDays: 7, autoAnalyze: false),
    );

    // A fresh controller (same prefs) reads the saved window back.
    final reloaded = build(_RecordingLibrary());
    addTearDown(reloaded.dispose);
    await reloaded.refresh();
    expect(reloaded.filters.sinceDays, 7);
    expect(reloaded.filters.autoAnalyze, isFalse);
    expect(reloaded.sinceCutoff, DateTime(2026, 7, 23));
  });
}
