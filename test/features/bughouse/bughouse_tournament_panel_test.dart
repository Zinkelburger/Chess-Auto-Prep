/// The match panel, on screen.
///
/// The wiring is what these cover: that a finished match leads with the
/// opening's score rather than the crosstable's Elo, that a game clicked in
/// the table lands on the lab's own two boards, and that entering the match
/// mode lets go of the engine — one process answers one question at a time, so
/// a match cannot share it with the analysis pump.
library;

import 'dart:io';

import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_controller.dart';
import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_tournament_controller.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_history.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_tournament.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_tournament_store.dart';
import 'package:chess_auto_prep/features/bughouse/widgets/bughouse_tournament_panel.dart';
import 'package:chess_auto_prep/models/game_outcome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bughouse_engine.dart';

BughouseGameRecord _game(int number, GameResult result) => BughouseGameRecord(
  number: number,
  whiteIndex: number.isOdd ? 0 : 1,
  blackIndex: number.isOdd ? 1 : 0,
  whiteName: number.isOdd ? 'A + C' : 'B + D',
  blackName: number.isOdd ? 'B + D' : 'A + C',
  result: result,
  termination: TerminationReason.checkmate,
  detail: 'board 1',
  moves: const ['1f2f3', '1e7e5', '1g2g4', '1d8h4'],
  startedAt: DateTime(2026, 9, 4),
  durationMs: 30000,
);

BughouseTournamentConfig _config() => BughouseTournamentConfig(
  name: 'd4 d5 Bf4',
  startDualFen: BughouseState.initial().dualFen,
  openingLabel: 'Board 1: d4 d5 Bf4',
  games: 2,
  seed: 3,
);

/// Two frames instead of `pumpAndSettle`.
///
/// The match controller reads its directory on init, and real file I/O does
/// not complete inside the fake-async zone `testWidgets` runs in — so the load
/// has to be driven through `runAsync`, and while it is outstanding a spinner
/// is on screen, which `pumpAndSettle` would wait on forever. Same reasoning
/// as the engine tournament's screen test.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bughouse-panel');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// A match controller reading from a temp directory, with [games] already
  /// played into it. Must be called inside `tester.runAsync`.
  Future<BughouseTournamentController> matchesWith(
    List<BughouseGameRecord> games, {
    void Function(BughouseHistory)? showLine,
  }) async {
    final store = BughouseTournamentStore(root);
    final created = await store.create(_config());
    await store.save(
      created.copyWith(
        games: games,
        status: BughouseTournamentStatus.completed,
      ),
    );
    final controller = BughouseTournamentController(
      acquireEngine: () async => FakeBughouseEngine(),
      showLine: showLine ?? (_) {},
      store: store,
    );
    for (var i = 0; i < 200 && controller.isLoading; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return controller;
  }

  Future<void> pump(WidgetTester tester, BughouseController controller) async {
    // The panel is only ever on screen in this mode, and the mode is what
    // stops the analysis pump — without it the lab keeps a search running
    // underneath the match, which is both wrong and a pending timer at
    // teardown.
    controller.setMode(BughouseMode.tournament);
    tester.view.physicalSize = const Size(700, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 540,
            child: BughouseTournamentPanel(controller: controller),
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  testWidgets('with nothing run, the panel says what a match is for', (
    tester,
  ) async {
    final controller = BughouseController(engineOverride: FakeBughouseEngine());
    addTearDown(controller.dispose);
    final matches = (await tester.runAsync(() => matchesWith(const [])))!;
    addTearDown(matches.dispose);
    // A run with no games at all is what a fresh install looks like once one
    // directory exists, and the panel still has to say what a match is for.
    controller.tournamentsOverride = matches;

    await pump(tester, controller);

    expect(find.text('New match'), findsOneWidget);
    expect(find.text('WHITE ON BOARD 1 SCORED'), findsOneWidget);
    expect(find.text('No games yet'), findsOneWidget);
  });

  testWidgets('a finished match leads with the opening\'s score', (
    tester,
  ) async {
    final matches = (await tester.runAsync(
      () => matchesWith([
        _game(1, GameResult.whiteWins),
        _game(2, GameResult.draw),
      ]),
    ))!;
    addTearDown(matches.dispose);
    final controller = BughouseController(engineOverride: FakeBughouseEngine())
      ..tournamentsOverride = matches;
    addTearDown(controller.dispose);

    await pump(tester, controller);

    expect(find.text('WHITE ON BOARD 1 SCORED'), findsOneWidget);
    // A win and a draw, read from the same side of the line both times — even
    // though the seats swapped for game 2.
    expect(find.text('1½/2'), findsOneWidget);
    expect(find.text('Board 1: d4 d5 Bf4'), findsOneWidget);
    // Both games are rows, headed by the seats rather than by "White".
    expect(find.text('A + C (White on 1)'), findsOneWidget);
    expect(find.text('1-0'), findsOneWidget);
    expect(find.text('1/2-1/2'), findsOneWidget);
  });

  testWidgets('clicking a game puts it on the boards', (tester) async {
    final controller = BughouseController(engineOverride: FakeBughouseEngine());
    addTearDown(controller.dispose);
    final matches = (await tester.runAsync(
      () => matchesWith([
        _game(1, GameResult.blackWins),
      ], showLine: controller.showLine),
    ))!;
    addTearDown(matches.dispose);
    controller.tournamentsOverride = matches;

    await pump(tester, controller);
    await tester.tap(find.text('0-1'));
    await _settle(tester);

    expect(matches.openGameNumber, 1);
    // Replayed onto the lab's own line, opening at the start so it can be
    // walked.
    expect(controller.history.length, 4);
    expect(controller.history.cursor, 0);
    controller.toEnd();
    expect(controller.state.boardA.isCheckmate, isTrue);
  });

  test('entering the match mode stops the analysis pump', () async {
    final engine = FakeBughouseEngine();
    final controller = BughouseController(engineOverride: engine);
    addTearDown(controller.dispose);

    controller.startAnalysis();
    for (var i = 0; i < 200 && engine.searches.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(engine.searches, isNotEmpty, reason: 'the pump was running');

    controller.setMode(BughouseMode.tournament);
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final settled = engine.searches.length;
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(engine.searches.length, settled);
  });
}
