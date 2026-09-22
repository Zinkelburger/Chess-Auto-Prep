/// The games header's offline line: when the rows came off this computer
/// rather than the sites, the bar says so — beside the games, never instead
/// of them.
library;

import 'dart:io' show SocketException;

import 'package:chess_auto_prep/features/games/controllers/recent_games_controller.dart';
import 'package:chess_auto_prep/features/games/services/games_window.dart';
import 'package:chess_auto_prep/features/games/widgets/games_home_header.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves a fixed PGN; [stale] makes it report that the games came from the
/// cache, exactly as the real library does with no connection.
class _FakeLibrary extends GamesLibraryService {
  _FakeLibrary(this.pgn, {this.stale = false});

  final String pgn;
  final bool stale;

  @override
  Future<List<GameRecord>> getGames({
    required GamesPlatform platform,
    required String username,
    GameSelection selection = const GameSelection(),
    List<GameSelection> unionWith = const [],
    bool forceRefresh = false,
    void Function(String message)? onProgress,
    void Function(DateTime fetchedAt)? onFetched,
    void Function(Object? error)? onStaleCache,
  }) async {
    if (stale) onStaleCache?.call(const SocketException('Failed host lookup'));
    return GamesLibraryService.selectFromPgnUnion(pgn, [
      selection,
      ...unionWith,
    ]);
  }

  @override
  Future<String> cacheFilePath(GamesPlatform platform, String username) async =>
      '/tmp/${platform.name}_$username.pgn';
}

const _pgn =
    '[Event "Rated blitz game"]\n'
    '[Site "https://lichess.org/g1"]\n'
    '[White "me"]\n'
    '[Black "opp"]\n'
    '[UTCDate "2026.08.04"]\n'
    '[UTCTime "10:00:00"]\n'
    '[TimeControl "300+0"]\n'
    '[WhiteElo "2100"]\n'
    '[Result "1-0"]\n'
    '\n'
    '1. e4 e5 1-0';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A loaded controller. The load runs through [WidgetTester.runAsync]: it
  /// parses its games on a real isolate (`compute`), which the widget test's
  /// fake clock would otherwise never let finish.
  Future<RecentGamesController> loaded(
    WidgetTester tester, {
    required bool stale,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final controller = RecentGamesController(
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      library: _FakeLibrary(_pgn, stale: stale),
      windowSettings: GamesWindowSettings.forTest(),
      now: () => DateTime(2026, 8, 4, 12),
    );
    await tester.runAsync(controller.refresh);
    return controller;
  }

  Future<void> pumpHeader(WidgetTester tester, RecentGamesController c) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GamesHomeHeader(controller: c, onSearchChanged: (_) {}),
          ),
        ),
      );

  testWidgets('cached games are labelled, and the games stay', (tester) async {
    final controller = await loaded(tester, stale: true);
    addTearDown(controller.dispose);
    await pumpHeader(tester, controller);

    expect(controller.games, hasLength(1));
    expect(find.textContaining('showing saved games'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
  });

  testWidgets('a load that reached the site says nothing', (tester) async {
    final controller = await loaded(tester, stale: false);
    addTearDown(controller.dispose);
    await pumpHeader(tester, controller);

    expect(find.textContaining('showing saved games'), findsNothing);
    expect(find.byIcon(Icons.cloud_off), findsNothing);
  });
}
