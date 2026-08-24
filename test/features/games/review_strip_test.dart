/// The review strip: the tactics home's three buttons in one column — the
/// engine-analysis job, then Study tactics and Opening review under a rule —
/// the state of the analysis in words, and how hard the engine is allowed to
/// work stated on screen with its own dialog to change it.
library;

import 'package:chess_auto_prep/features/games/controllers/recent_games_controller.dart';
import 'package:chess_auto_prep/features/games/services/games_window.dart';
import 'package:chess_auto_prep/features/games/services/home_review_runner.dart';
import 'package:chess_auto_prep/features/games/widgets/review_strip.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:chess_auto_prep/features/tactics/services/mining_settings.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_import_coordinator.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';
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
/// wait for. What the strip *does* with that state is what is under test here;
/// how it gets there is covered in `home_review_runner_test.dart`.
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
    VoidCallback? onStudy,
    VoidCallback? onSettings,
    VoidCallback? onOpeningReview,
    ValueChanged<bool>? onAutoRunChanged,
    bool autoRun = true,
    int unreviewed = 3,
    int ready = 12,
    int openingIssues = 4,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          child: ReviewStrip(
            runner: runner,
            coordinator: coordinator,
            isLoadingGames: false,
            gamesInWindow: 20,
            unreviewedCount: unreviewed,
            windowLabel: 'last 20 games',
            readyPuzzleCount: ready,
            openingIssueCount: openingIssues,
            autoRun: autoRun,
            onAutoRunChanged: onAutoRunChanged ?? (_) {},
            onStart: onStart ?? () {},
            onPause: onPause ?? () {},
            onStudyTactics: onStudy ?? () {},
            onRefresh: () {},
            onSettings: onSettings ?? () {},
            onOpeningReview: onOpeningReview ?? () {},
          ),
        ),
      ),
    ),
  );

  testWidgets('idle: a play button and the work waiting beside it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    await pump(tester, runner: h.runner, coordinator: h.co);

    expect(find.byIcon(Icons.pause), findsNothing);
    expect(
      find.text('3 unanalysed games'),
      findsOneWidget,
      reason: 'the strip leads with the work waiting, not a game count',
    );
    expect(
      find.textContaining('Out of 20'),
      findsNothing,
      reason: 'restating the window under the count was a fact without a use',
    );
  });

  /// The transport button's fill, which is how the strip says whether this is
  /// the thing to press.
  Color? transportColor(WidgetTester tester) => tester
      .widget<FilledButton>(find.byKey(const Key('review-transport-button')))
      .style
      ?.backgroundColor
      ?.resolve({});

  testWidgets('with games waiting the job button is green, not scenery', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);
    final flips = <bool>[];

    // 3 of 20 unanalysed: pressing it would do real work.
    await pump(
      tester,
      runner: h.runner,
      coordinator: h.co,
      onAutoRunChanged: flips.add,
    );

    expect(transportColor(tester), AppColors.successSurface);
    // …and it glows while it asks. The glow is a shadow so the buttons under
    // it never move.
    expect(
      find.ancestor(
        of: find.byKey(const Key('review-transport-button')),
        matching: find.byType(DecoratedBox),
      ),
      findsWidgets,
    );

    await tester.tap(find.text('Auto-start'));
    expect(flips, [false], reason: 'auto-start is on, so the tap turns it off');
  });

  testWidgets('with nothing to analyse it goes back to gray', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    // Every game in the window is analysed: the button only offers to check
    // for new ones, which is not worth shouting about.
    await pump(tester, runner: h.runner, coordinator: h.co, unreviewed: 0);

    expect(transportColor(tester), AppColors.surfaceInset);
    expect(find.text('Check for new games'), findsOneWidget);
  });

  testWidgets('the button offers to resume when only some games are analysed', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    // 3 of 20 left: the app was closed mid-review, so the button must not
    // pretend this is a fresh start. The count lives in the headline beside
    // the button, not in its label.
    await pump(tester, runner: h.runner, coordinator: h.co);
    expect(find.text('Resume engine analysis'), findsOneWidget);
    expect(find.text('3 unanalysed games'), findsOneWidget);

    // Nothing analysed yet — a first run.
    await pump(tester, runner: h.runner, coordinator: h.co, unreviewed: 20);
    expect(find.text('Start engine analysis'), findsOneWidget);
    expect(find.text('20 unanalysed games'), findsOneWidget);

    // All caught up: pressing play only looks for new games.
    await pump(tester, runner: h.runner, coordinator: h.co, unreviewed: 0);
    expect(find.text('Check for new games'), findsOneWidget);
  });

  testWidgets('all three buttons are in one column, the job first', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    await pump(tester, runner: h.runner, coordinator: h.co);

    final analysis = tester.getTopLeft(find.text('Resume engine analysis'));
    final study = tester.getTopLeft(find.text('Study tactics (12)'));
    final opening = tester.getTopLeft(find.text('Opening review (4)'));
    expect(
      study.dy,
      greaterThan(analysis.dy),
      reason: 'the job button is on top',
    );
    expect(
      opening.dy,
      greaterThan(study.dy),
      reason: 'opening review is the third button, not off in the icon row',
    );
    final analysisBox = tester.getRect(
      find.byKey(const Key('review-transport-button')),
    );
    final studyBox = tester.getRect(
      find.byKey(const Key('study-tactics-button')),
    );
    final openingBox = tester.getRect(
      find.byKey(const Key('opening-review-button')),
    );
    expect(studyBox.left, analysisBox.left, reason: 'one column');
    expect(openingBox.left, analysisBox.left, reason: 'one column');
    expect(
      studyBox.top - analysisBox.bottom,
      greaterThan((openingBox.top - studyBox.bottom) * 2),
      reason:
          'the job is separated from the two result buttons by much more than '
          'they are from each other',
    );
  });

  testWidgets('a rule separates the job from the two result buttons', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    await pump(tester, runner: h.runner, coordinator: h.co);

    final rule = tester.getRect(find.byType(Divider));
    final analysis = tester.getRect(
      find.byKey(const Key('review-transport-button')),
    );
    final study = tester.getRect(find.byKey(const Key('study-tactics-button')));
    expect(rule.top, greaterThan(analysis.bottom));
    expect(rule.bottom, lessThan(study.top));
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

  testWidgets('the study button plays the puzzles, and is dead without any', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);
    var studied = 0;

    await pump(
      tester,
      runner: h.runner,
      coordinator: h.co,
      onStudy: () => studied++,
    );
    await tester.tap(find.text('Study tactics (12)'));
    expect(studied, 1);

    await pump(tester, runner: h.runner, coordinator: h.co, ready: 0);
    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('study-tactics-button')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('Study tactics'), findsOneWidget);
  });

  testWidgets('the play button starts the analysis', (tester) async {
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

  testWidgets('cores and depth are stated on the strip, not steppered', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = build();
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    await pump(tester, runner: h.runner, coordinator: h.co);

    expect(find.textContaining('CPU cores'), findsOneWidget);
    expect(find.textContaining('engine depth'), findsOneWidget);
    expect(
      find.byIcon(Icons.remove),
      findsNothing,
      reason: 'the plus/minus steppers are gone',
    );
  });

  testWidgets('one gear, and it is the only way into the settings', (
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
      onSettings: () => opened++,
    );

    expect(
      find.text('Review speed…'),
      findsNothing,
      reason: 'cores and depth live behind the gear now, not their own button',
    );
    expect(find.byIcon(Icons.tune), findsNothing);
    await tester.tap(find.byIcon(Icons.settings));
    expect(opened, 1);
  });

  testWidgets('with no account the button is disabled and says why', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = build(lichess: null);
    addTearDown(h.games.dispose);
    addTearDown(h.runner.dispose);

    await pump(tester, runner: h.runner, coordinator: h.co);

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(find.textContaining('No account set'), findsOneWidget);
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

    expect(find.text('Resume engine analysis'), findsOneWidget);
    expect(find.text('Paused — 3 games left'), findsOneWidget);
    expect(
      find.textContaining('carry on where it stopped'),
      findsOneWidget,
      reason: 'pause never throws away what was already reviewed',
    );
  });
}
