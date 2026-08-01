/// The review pipeline: it starts paused, the stages go in order, pause stops
/// the engine pass with work left, and play carries on.
library;

import 'dart:async';

import 'package:chess_auto_prep/features/games/controllers/recent_games_controller.dart';
import 'package:chess_auto_prep/features/games/services/home_review_runner.dart';
import 'package:chess_auto_prep/features/games/services/games_window.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:chess_auto_prep/services/tactics/mining_settings.dart';
import 'package:chess_auto_prep/services/tactics/tactics_import_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _EmptyLibrary extends GamesLibraryService {
  int fetches = 0;

  @override
  Future<List<GameRecord>> getGames({
    required GamesPlatform platform,
    required String username,
    GameSelection selection = const GameSelection(),
    bool forceRefresh = false,
    void Function(String message)? onProgress,
  }) async {
    fetches++;
    return const [];
  }

  @override
  Future<String> cacheFilePath(GamesPlatform platform, String username) async =>
      '/tmp/${platform.name}_$username.pgn';
}

const _pgn =
    '[Event "Rated blitz game"]\n'
    '[Site "https://lichess.org/abc123"]\n'
    '[White "me"]\n'
    '[Black "opp"]\n'
    '[TimeControl "180+2"]\n'
    '[Result "1-0"]\n'
    '\n'
    // Long enough to have no `[%eval]`-derived summary: a game whose plies are
    // nearly all annotated counts as already reviewed (see summarizeGameReview),
    // and this one has to look unreviewed.
    '1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 1-0';

/// One downloaded game, so the review has something already in hand.
class _OneGameLibrary extends GamesLibraryService {
  @override
  Future<List<GameRecord>> getGames({
    required GamesPlatform platform,
    required String username,
    GameSelection selection = const GameSelection(),
    bool forceRefresh = false,
    void Function(String message)? onProgress,
  }) async => [GameRecord.parse(_pgn)];

  @override
  Future<String> cacheFilePath(GamesPlatform platform, String username) async =>
      '/tmp/${platform.name}_$username.pgn';
}

/// Records the engine-pass calls without touching the network or an engine.
class _RecordingCoordinator extends TacticsImportCoordinator {
  final imports = <TacticsImportParams>[];

  /// Whether each call was handed already-downloaded games (rather than being
  /// told to fetch them itself).
  final gotPgns = <bool>[];

  /// The games each call was told to analyse regardless of the analyzed flag.
  final forced = <Set<String>>[];
  int cancels = 0;

  @override
  Future<bool> import({
    required TacticsImportSource source,
    required TacticsImportParams params,
    String? pgnContent,
    Set<String> forceDedupKeys = const {},
  }) async {
    imports.add(params);
    gotPgns.add(pgnContent != null);
    forced.add(forceDedupKeys);
    return true;
  }

  @override
  void cancelImport() => cancels++;
}

/// An engine pass that does not finish the moment it is asked to stop — which
/// is the real thing's behaviour, and the only way to press play *during* a
/// wind-down. Refuses a second concurrent pass the way the real coordinator
/// does (it still holds the engine pool).
class _BlockingCoordinator extends TacticsImportCoordinator {
  int imports = 0;
  int cancels = 0;

  /// Times a pass was turned away because another still held the pool.
  int refusals = 0;

  Completer<bool>? _pending;

  @override
  Future<bool> import({
    required TacticsImportSource source,
    required TacticsImportParams params,
    String? pgnContent,
    Set<String> forceDedupKeys = const {},
  }) async {
    if (_pending != null) {
      refusals++;
      return false;
    }
    imports++;
    final completer = Completer<bool>();
    _pending = completer;
    final completed = await completer.future;
    _pending = null;
    return completed;
  }

  @override
  void cancelImport() => cancels++;

  /// The pass finally lets go of the pool, reporting it did not finish.
  void finishCancelled() => _pending!.complete(false);

  /// The pass runs to completion.
  void finish() => _pending!.complete(true);
}

/// Let the event loop run until [done] holds. A fixed `pumpEventQueue()` is
/// not enough: how many turns the pipeline needs to reach the engine pass
/// depends on the mocked prefs round-trips, and files running side by side
/// were flaky on a fixed count.
Future<void> pumpUntil(bool Function() done, {int times = 500}) async {
  for (var i = 0; i < times && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ({
    HomeReviewRunner runner,
    RecentGamesController games,
    _RecordingCoordinator coordinator,
    _EmptyLibrary library,
  })
  build({String? lichess = 'me', String? chesscom}) {
    final library = _EmptyLibrary();
    final games = RecentGamesController(
      lichessUsername: () => lichess,
      chesscomUsername: () => chesscom,
      library: library,
      windowSettings: GamesWindowSettings.forTest(),
    );
    final coordinator = _RecordingCoordinator();
    return (
      runner: HomeReviewRunner(
        games: games,
        importCoordinator: coordinator,
        lichessUsername: () => lichess,
        chesscomUsername: () => chesscom,
        windowSettings: GamesWindowSettings.forTest(),
        miningSettings: MiningSettings.forTest(),
      ),
      games: games,
      coordinator: coordinator,
      library: library,
    );
  }

  test('idle until play — constructing it starts nothing', () {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    expect(h.runner.stage, HomeReviewStage.idle);
    expect(h.runner.isRunning, isFalse);
    expect(h.runner.canResume, isFalse);
    expect(h.library.fetches, 0);
    expect(h.coordinator.imports, isEmpty);
  });

  test('start() walks fetch → openings → review and ends done', () async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    final seen = <HomeReviewStage>[];
    h.runner.addListener(() {
      if (seen.isEmpty || seen.last != h.runner.stage) seen.add(h.runner.stage);
    });

    await h.runner.start();

    // Three stages, not four: the engine pass that mines the puzzles is the
    // same pass that counts the mistakes, so there is no separate "analyzing".
    expect(seen, [
      HomeReviewStage.fetching,
      HomeReviewStage.openings,
      HomeReviewStage.reviewing,
      HomeReviewStage.done,
    ]);
    expect(h.library.fetches, 1);
    expect(h.coordinator.imports, hasLength(1));
    expect(h.runner.isRunning, isFalse);
  });

  test(
    'the engine pass uses the shared window: a game cap, no date cutoff',
    () async {
      SharedPreferences.setMockInitialValues({});
      final h = build();
      addTearDown(h.games.dispose);
      addTearDown(h.runner.dispose);

      await h.runner.start();

      final params = h.coordinator.imports.single;
      expect(params.username, 'me');
      expect(params.mode, TacticsImportMode.recent);
      expect(params.maxGames, GamesWindow.defaultGames);
      expect(params.since, isNull);
      expect(params.depth, MiningSettings.defaultDepth);
    },
  );

  test('every configured site is reviewed, in turn', () async {
    SharedPreferences.setMockInitialValues({});
    final h = build(lichess: 'me', chesscom: 'me2');
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    await h.runner.start();

    expect(h.coordinator.imports.map((p) => p.username), ['me', 'me2']);
  });

  test('with no username there is nothing to start', () {
    SharedPreferences.setMockInitialValues({});
    final h = build(lichess: null);
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    expect(h.runner.hasAnySource, isFalse);
  });

  test(
    'pause stops the run, reaches the engine, and offers to resume',
    () async {
      SharedPreferences.setMockInitialValues({});
      final h = build();
      addTearDown(h.games.dispose);
      addTearDown(h.runner.dispose);

      final run = h.runner.start();
      h.runner.pause();
      await run;

      expect(h.runner.stage, HomeReviewStage.paused);
      expect(h.runner.canResume, isTrue, reason: 'play means "carry on" now');
      expect(h.coordinator.cancels, 1);
      // The pause landed during the first stage, so the engine pass never ran.
      expect(h.coordinator.imports, isEmpty);
    },
  );

  test('a paused run carries on when play is pressed again', () async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    final run = h.runner.start();
    h.runner.pause();
    await run;
    expect(h.coordinator.imports, isEmpty);

    await h.runner.start();

    expect(h.runner.stage, HomeReviewStage.done);
    expect(h.coordinator.imports, hasLength(1));
  });

  test('reset puts it back to idle after the window changed', () async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    await h.runner.start();
    expect(h.runner.stage, HomeReviewStage.done);

    h.runner.reset();
    expect(h.runner.stage, HomeReviewStage.idle);
  });

  test('the games it just downloaded are handed to the engine pass, not '
      'fetched again', () async {
    SharedPreferences.setMockInitialValues({});
    final games = RecentGamesController(
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      library: _OneGameLibrary(),
      windowSettings: GamesWindowSettings.forTest(),
    );
    final coordinator = _RecordingCoordinator();
    final runner = HomeReviewRunner(
      games: games,
      importCoordinator: coordinator,
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      windowSettings: GamesWindowSettings.forTest(),
      miningSettings: MiningSettings.forTest(),
    );
    addTearDown(games.dispose);
    addTearDown(runner.dispose);

    await runner.start();

    expect(coordinator.gotPgns, [true]);
  });

  test('games the list has no counts for are named for re-analysis', () async {
    SharedPreferences.setMockInitialValues({});
    final games = RecentGamesController(
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      library: _OneGameLibrary(),
      windowSettings: GamesWindowSettings.forTest(),
    );
    final coordinator = _RecordingCoordinator();
    final runner = HomeReviewRunner(
      games: games,
      importCoordinator: coordinator,
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      windowSettings: GamesWindowSettings.forTest(),
      miningSettings: MiningSettings.forTest(),
    );
    addTearDown(games.dispose);
    addTearDown(runner.dispose);

    await runner.start();

    // Without this the pass skips it as "already analyzed" — which only ever
    // meant "already mined" — and the strip's "1 game to analyse" never moves.
    expect(coordinator.forced, [
      {'https://lichess.org/abc123'},
    ]);
  });

  test('with nothing downloaded the engine pass fetches for itself', () async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    await h.runner.start();

    // The list is empty (a failed or filtered-out fetch); handing the pass an
    // empty PGN would silently review nothing.
    expect(h.coordinator.gotPgns, [false]);
  });

  test('play pressed while the run is still stopping resumes it', () async {
    SharedPreferences.setMockInitialValues({});
    final games = RecentGamesController(
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      library: _EmptyLibrary(),
      windowSettings: GamesWindowSettings.forTest(),
    );
    final coordinator = _BlockingCoordinator();
    final runner = HomeReviewRunner(
      games: games,
      importCoordinator: coordinator,
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      windowSettings: GamesWindowSettings.forTest(),
      miningSettings: MiningSettings.forTest(),
    );
    addTearDown(games.dispose);
    addTearDown(runner.dispose);

    final run = runner.start();
    await pumpUntil(() => coordinator.imports == 1);
    expect(coordinator.imports, 1, reason: 'the engine pass is under way');

    runner.pause();
    // Pause reports itself at once, so the button already reads Resume while
    // the engine is still finishing the game it is in.
    expect(runner.stage, HomeReviewStage.paused);
    unawaited(runner.start());

    coordinator.finishCancelled();
    await pumpUntil(() => coordinator.imports == 2);

    // The queued resume waited for the pool instead of starting a second
    // pipeline on top of the first: starting one there was refused (the pool
    // was still held), which set the pause flag again and killed both runs —
    // pressing Resume too soon did nothing at all.
    expect(coordinator.refusals, 0);
    expect(coordinator.imports, 2);

    coordinator.finish();
    await run;
    expect(runner.stage, HomeReviewStage.done);
  });

  test('pause during the wind-down cancels the queued resume', () async {
    SharedPreferences.setMockInitialValues({});
    final games = RecentGamesController(
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      library: _EmptyLibrary(),
      windowSettings: GamesWindowSettings.forTest(),
    );
    final coordinator = _BlockingCoordinator();
    final runner = HomeReviewRunner(
      games: games,
      importCoordinator: coordinator,
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      windowSettings: GamesWindowSettings.forTest(),
      miningSettings: MiningSettings.forTest(),
    );
    addTearDown(games.dispose);
    addTearDown(runner.dispose);

    final run = runner.start();
    await pumpUntil(() => coordinator.imports == 1);
    runner.pause();
    unawaited(runner.start());
    runner.pause(); // changed their mind before the engine let go

    coordinator.finishCancelled();
    await run;

    expect(coordinator.imports, 1, reason: 'the queued resume was called off');
    expect(runner.stage, HomeReviewStage.paused);
  });

  test('a second start() while one is going is ignored, not queued', () async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    final first = h.runner.start();
    await h.runner.start();
    await first;

    expect(h.library.fetches, 1);
    expect(h.coordinator.imports, hasLength(1));
  });
}
