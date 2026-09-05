/// The Analysis and Openings blocks of the tactics home column: the engine
/// job as one button that says what pressing it does, the state of the
/// analysis in words, and the opening review under it. No settings on the
/// blocks — those are behind the gear.
library;

import 'package:chess_auto_prep/features/games/controllers/recent_games_controller.dart';
import 'package:chess_auto_prep/features/games/services/games_window.dart';
import 'package:chess_auto_prep/features/games/models/recent_game.dart';
import 'package:chess_auto_prep/features/games/services/game_deviation_service.dart';
import 'package:chess_auto_prep/features/games/services/home_review_runner.dart';
import 'package:chess_auto_prep/features/games/services/opening_review.dart';
import 'package:chess_auto_prep/features/games/widgets/analysis_block.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:chess_auto_prep/features/tactics/services/mining_settings.dart';
import 'package:chess_auto_prep/models/engine_settings.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_import_coordinator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _IdleLibrary extends GamesLibraryService {
  @override
  Future<List<GameRecord>> getGames({
    required GamesPlatform platform,
    required String username,
    GameSelection selection = const GameSelection(),
    List<GameSelection> unionWith = const [],
    bool forceRefresh = false,
    void Function(String message)? onProgress,
    void Function(DateTime fetchedAt)? onFetched,
  }) async => const [];

  @override
  Future<String> cacheFilePath(GamesPlatform platform, String username) async =>
      '/tmp/${platform.name}_$username.pgn';
}

class _StubCoordinator extends TacticsImportCoordinator {
  @override
  Future<bool> import({
    required TacticsImportSource source,
    required TacticsImportParams params,
    String? pgnContent,
    Set<String> forceDedupKeys = const {},
  }) async => true;
}

/// A runner parked in the paused state, without running anything: the real
/// pipeline hops through `compute`, which a widget test's fake clock cannot
/// wait for.
class _PausedRunner extends HomeReviewRunner {
  _PausedRunner({
    required super.games,
    required super.importCoordinator,
    required super.lichessUsername,
    required super.chesscomUsername,
    super.windowSettings,
    super.miningSettings,
  });

  @override
  HomeReviewStage get stage => HomeReviewStage.paused;

  @override
  bool get canResume => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ({HomeReviewRunner runner, RecentGamesController games, _StubCoordinator co})
  build({String? lichess = 'me'}) {
    final games = RecentGamesController(
      lichessUsername: () => lichess,
      chesscomUsername: () => null,
      library: _IdleLibrary(),
      windowSettings: GamesWindowSettings.forTest(),
    );
    final co = _StubCoordinator();
    return (
      runner: HomeReviewRunner(
        games: games,
        importCoordinator: co,
        lichessUsername: () => lichess,
        chesscomUsername: () => null,
        windowSettings: GamesWindowSettings.forTest(),
        miningSettings: MiningSettings.forTest(),
      ),
      games: games,
      co: co,
    );
  }

  Future<void> pump(
    WidgetTester tester, {
    required HomeReviewRunner runner,
    required TacticsImportCoordinator coordinator,
    VoidCallback? onStart,
    VoidCallback? onPause,
    VoidCallback? onSettings,
    VoidCallback? onOpeningReview,
    VoidCallback? onMasterPractice,
    List<OpeningReviewEntry> repeated = const [],
    void Function(OpeningReviewEntry)? onFixEntry,
    int masterGameCount = 0,
    int unreviewed = 3,
    int openingIssues = 4,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 380,
          child: Column(
            children: [
              AnalysisBlock(
                runner: runner,
                coordinator: coordinator,
                isLoadingGames: false,
                gamesInWindow: 20,
                unreviewedCount: unreviewed,
                windowLabel: 'last 20 games',
                onStart: onStart ?? () {},
                onPause: onPause ?? () {},
                onSettings: onSettings ?? () {},
              ),
              OpeningsBlock(
                openingIssueCount: openingIssues,
                gamesInWindow: 20,
                windowLabel: 'last 20 games',
                onOpeningReview: onOpeningReview ?? () {},
                masterGameCount: masterGameCount,
                onMasterPractice: onMasterPractice ?? () {},
                repeated: repeated,
                onFixEntry: onFixEntry,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  testWidgets('idle: the work waiting is the headline, the count is on the '
      'button', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    await pump(tester, runner: h.runner, coordinator: h.co);

    expect(find.byIcon(Icons.pause), findsNothing);
    expect(find.text('3 of 20 games not analysed'), findsOneWidget);
    // 3 of 20 left: the app was closed mid-review, so the button must not
    // pretend this is a fresh start.
    expect(find.text('Resume analysis'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });

  testWidgets('a first run says how many games it will analyse', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    await pump(tester, runner: h.runner, coordinator: h.co, unreviewed: 20);
    expect(find.text('Analyse 20 games'), findsOneWidget);
    expect(find.text('20 of 20 games not analysed'), findsOneWidget);
  });

  testWidgets('with nothing to analyse it only offers to check for new games', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    await pump(tester, runner: h.runner, coordinator: h.co, unreviewed: 0);

    expect(find.text('Check for new games'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(find.text('Finished analysing 20 games'), findsOneWidget);
    expect(
      find.text('Your last 20 games are downloaded and analysed'),
      findsOneWidget,
    );
  });

  testWidgets('the blocks carry no settings: no checkbox, no CPU sentence', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    await pump(tester, runner: h.runner, coordinator: h.co);

    expect(find.text('Auto-start'), findsNothing);
    expect(find.textContaining('CPU cores'), findsNothing);
    expect(find.textContaining('engine depth'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('the core count is stated beside the gear and follows the '
      'setting', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);
    final engine = EngineSettings.instance;
    final before = engine.workers;
    addTearDown(() => engine.workers = before);
    engine.workers = 1;

    await pump(tester, runner: h.runner, coordinator: h.co);
    expect(find.text('1 core'), findsOneWidget);

    engine.workers = 2;
    await tester.pump();
    expect(find.text('2 cores'), findsOneWidget);
  });

  testWidgets('the gear is the one way into the settings', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);
    var opened = 0;

    await pump(
      tester,
      runner: h.runner,
      coordinator: h.co,
      onSettings: () => opened++,
    );
    await tester.tap(find.byTooltip('Analysis settings…'));
    expect(opened, 1);
  });

  testWidgets('opening review is a button with its leak count, and opens', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);
    var opened = 0;

    await pump(
      tester,
      runner: h.runner,
      coordinator: h.co,
      onOpeningReview: () => opened++,
    );
    expect(find.text('Opening review (4)'), findsOneWidget);
    expect(find.text('4 places your games left your books'), findsOneWidget);
    await tester.tap(find.byKey(const Key('opening-review-button')));
    expect(opened, 1);

    // Nothing to review is not a dead button: only the dialog can say whether
    // that means "no leaks" or "no book designated".
    await pump(tester, runner: h.runner, coordinator: h.co, openingIssues: 0);
    expect(find.text('Opening review'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('opening-review-button')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('the button starts the analysis', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);
    var started = 0;

    await pump(
      tester,
      runner: h.runner,
      coordinator: h.co,
      onStart: () => started++,
    );
    await tester.tap(find.byKey(const Key('review-transport-button')));

    expect(started, 1);
  });

  testWidgets('with no account the button is disabled and says why', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = build(lichess: null);
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    await pump(tester, runner: h.runner, coordinator: h.co);

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('review-transport-button')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('No account set'), findsOneWidget);
  });

  testWidgets('a paused run offers Resume, not a fresh start', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final games = RecentGamesController(
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      library: _IdleLibrary(),
      windowSettings: GamesWindowSettings.forTest(),
    );
    final co = _StubCoordinator();
    final runner = _PausedRunner(
      games: games,
      importCoordinator: co,
      lichessUsername: () => 'me',
      chesscomUsername: () => null,
      windowSettings: GamesWindowSettings.forTest(),
      miningSettings: MiningSettings.forTest(),
    );
    addTearDown(games.dispose);
    addTearDown(runner.dispose);

    await pump(tester, runner: runner, coordinator: co);

    expect(find.text('Resume analysis'), findsOneWidget);
    expect(find.text('Paused — 3 games left'), findsOneWidget);
    expect(
      find.textContaining('carry on where it stopped'),
      findsOneWidget,
      reason: 'pause never throws away what was already reviewed',
    );
  });

  group('repeated leaks', () {
    RecentGame gameWith(DeviationReport report, int n) {
      final game = RecentGame(
        record: GameRecord(
          pgn: '',
          headers: const {'White': 'me', 'Black': 'opp', 'Result': '1-0'},
          date: DateTime(2026, 7, 20),
          speed: GameSpeed.blitz,
          dedupKey: 'g$n',
        ),
        platform: GamesPlatform.lichess,
        cachePath: '/tmp/lichess_me.pgn',
        myUsername: 'me',
        meWhite: true,
        sans: const [],
      );
      game
        ..deviation = report
        ..deviationComputed = true
        ..bookDesignated = true;
      return game;
    }

    testWidgets('lists each repeated point with its count and opens it', (
      tester,
    ) async {
      final b = build();
      const leak = DeviationReport(
        matchedPlies: 4,
        chapterPath: '/r/alapin.pgn',
        chapterName: 'Alapin',
        pathSans: ['e4', 'c5', 'c3', 'd5'],
        playedSan: 'Nf3',
        byMe: true,
        expectedSans: ['exd5'],
      );
      const end = DeviationReport(
        matchedPlies: 4,
        chapterPath: '/r/benko.pgn',
        chapterName: 'Benko',
        pathSans: ['d4', 'Nf6', 'c4', 'c5'],
        playedSan: 'd5',
      );
      final review = aggregateOpeningReview([
        gameWith(leak, 1),
        gameWith(leak, 2),
        gameWith(leak, 3),
        gameWith(end, 4),
        gameWith(end, 5),
      ]);
      OpeningReviewEntry? fixed;
      await pump(
        tester,
        runner: b.runner,
        coordinator: b.co,
        repeated: review.repeated(),
        onFixEntry: (e) => fixed = e,
      );

      expect(find.text('Keeps happening'), findsOneWidget);
      expect(find.text('3×'), findsOneWidget);
      expect(find.text('2×'), findsOneWidget);
      expect(find.text('Alapin · 3. Nf3'), findsOneWidget);
      expect(find.text('Benko · book ends at move 3'), findsOneWidget);
      expect(find.text('Fix'), findsOneWidget);
      expect(find.text('Extend'), findsOneWidget);

      await tester.tap(find.text('Extend'));
      expect(fixed?.chapterName, 'Benko');
    });

    testWidgets('says nothing when nothing repeats', (tester) async {
      final b = build();
      await pump(tester, runner: b.runner, coordinator: b.co);
      expect(find.text('Keeps happening'), findsNothing);
    });
  });
}
