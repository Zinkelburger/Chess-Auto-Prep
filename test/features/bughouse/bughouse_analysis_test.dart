/// The analysis loop, driven by a scripted engine.
///
/// Everything here was unreachable before [BughouseAnalysisEngine] existed:
/// the controller's only injectable engine was a real Hivemind process, so the
/// pump, the generation invalidation, the borrowed eval and the scenario
/// comparison had no coverage at all — which is where four of the bugs these
/// tests pin were living.
library;

import 'dart:async';

import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_controller.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bughouse_engine.dart';

void main() {
  late FakeBughouseEngine engine;
  late BughouseController controller;

  setUp(() {
    engine = FakeBughouseEngine();
    controller = BughouseController(engineOverride: engine);
  });

  tearDown(() => controller.dispose());

  /// Lets the pump run until it has searched both teams at least once.
  Future<void> settle() async {
    controller.startAnalysis();
    for (var i = 0; i < 40 && engine.searches.length < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('the pump', () {
    test(
      'searches both teams, because a position has no single side to move',
      () async {
        await settle();
        final teams = engine.configurations.map((c) => c.team).toSet();
        expect(teams, {Side.white, Side.black});
      },
    );

    test('asks for the shortlist, and only constrains our own team', () async {
      controller.setRequireMoveOn(RequireMoveOn.boardA);
      await settle();

      final ours = engine.configurations.firstWhere(
        (c) => c.team == Side.white,
      );
      final theirs = engine.configurations.firstWhere(
        (c) => c.team == Side.black,
      );
      expect(ours.multiPv, controller.engineSettings.lines);
      // The constraint is ours to obey; the opponents are not bound by it.
      expect(ours.requireMoveOn, RequireMoveOn.boardA);
      expect(theirs.requireMoveOn, RequireMoveOn.none);
    });

    test('tells the engine the clock stance each team actually has', () async {
      controller.setTimeStance(BughouseTimeStance.ahead);
      await settle();

      final ours = engine.configurations.firstWhere(
        (c) => c.team == Side.white,
      );
      final theirs = engine.configurations.firstWhere(
        (c) => c.team == Side.black,
      );
      expect(ours.hasTimeAdvantage, isTrue);
      expect(theirs.hasTimeAdvantage, isFalse, reason: 'only one team may sit');
    });

    test(
      'stops and forgets everything when the pane goes off screen',
      () async {
        engine.resultsByTeam[Side.white] = scripted(best: '(d2d4,pass)');
        await settle();
        expect(controller.ours.best, isNotNull);

        controller.setOnScreen(false);
        await Future<void>.delayed(Duration.zero);

        expect(engine.stops, greaterThan(0));
        expect(controller.ours.isEmpty, isTrue, reason: 'the answer is stale');

        // And it does not quietly start thinking again while off screen.
        final before = engine.searches.length;
        controller.startAnalysis();
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(engine.searches.length, before);
      },
    );

    test(
      'a search that lands after the position moved on is dropped',
      () async {
        engine.searchDelay = const Duration(milliseconds: 20);
        engine.resultsByTeam[Side.white] = scripted(
          best: '(d2d4,pass)',
          cp: -100,
        );
        engine.searchStarted = Completer<void>();

        controller.startAnalysis();
        await engine.searchStarted!.future;

        // Play a move while the search is in flight.
        controller.playMove(
          BughouseBoard.a,
          NormalMove(from: Square.e2, to: Square.e4),
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));

        // The result belonged to the position before the move, so it is gone.
        expect(controller.ours.latest?.scoreCp, isNot(-100));
      },
    );
  });

  group('the eval', () {
    test(
      'is read against the baseline for the stance it was searched under',
      () async {
        // A dead-level position: about -2.3 with the option off.
        engine.resultsByTeam[Side.white] = scripted(
          best: '(d2d4,pass)',
          cp: -233,
        );
        await settle();
        expect(controller.eval!.label, '-0.03');
        expect(controller.eval!.winPercent, closeTo(50, 2));
        expect(controller.eval!.borrowed, isFalse);
      },
    );

    test('a "we may sit" search reads level too, not +4.7', () async {
      controller.setTimeStance(BughouseTimeStance.ahead);
      // The same level position, which the engine reports as +2.39 once it is
      // told the team may sit.
      engine.resultsByTeam[Side.white] = scripted(
        best: '(pass,pass)',
        cp: 239,
        hadTimeAdvantage: true,
      );
      await settle();
      expect(controller.eval!.label, '+0.09');
      expect(controller.eval!.winPercent, closeTo(50, 3));
    });

    test('is borrowed from their search when we hold no move', () async {
      // Board A: black to move (not ours). Board B: white to move (not ours).
      const a = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR[] b KQkq - 0 1';
      const b = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';
      expect(controller.loadDualFen('$a|$b'), isTrue);
      expect(controller.state.hasMoveFor(Side.white), isFalse);

      engine.resultsByTeam[Side.black] = scripted(
        best: '(e7e5,pass)',
        cp: -130,
      );
      controller.startAnalysis();
      for (var i = 0; i < 40 && engine.searches.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(Duration.zero);

      // Only the team with a move was asked.
      expect(engine.configurations.map((c) => c.team).toSet(), {Side.black});
      final eval = controller.eval!;
      expect(eval.borrowed, isTrue);
      expect(eval.label, '-1.00', reason: 'their +1.00 is our -1.00');
    });
  });

  group('the shortlist', () {
    test('every row of a block comes from the same finished search', () async {
      engine.resultsByTeam[Side.white] = scripted(
        best: '(d2d4,pass)',
        cp: -230,
        alternatives: [-260, -280],
      );
      await settle();

      final lines = controller.lines;
      expect(lines, hasLength(3));
      // One search, so one node count and one time across the whole block.
      expect(lines.map((l) => l.timeMs).toSet(), hasLength(1));
      expect(lines.map((l) => l.nodes).toSet(), hasLength(1));
    });
  });

  group('the scenario comparison', () {
    test(
      'runs each stance and reads every row against its own baseline',
      () async {
        await settle();
        engine.resultsByTeam[Side.white] = scripted(
          best: '(d2d4,pass)',
          cp: -230,
        );

        await controller.compareScenarios();

        expect(controller.scenarios, hasLength(3));
        final advantages = engine.configurations
            .sublist(engine.configurations.length - 3)
            .map((c) => c.hasTimeAdvantage)
            .toList();
        expect(advantages, [true, false, false]);
        final requires = engine.configurations
            .sublist(engine.configurations.length - 3)
            .map((c) => c.requireMoveOn)
            .toList();
        expect(requires, [
          RequireMoveOn.none,
          RequireMoveOn.none,
          RequireMoveOn.boardA,
        ]);
      },
    );

    test('abandons the table when the position changes under it', () async {
      await settle();
      engine.searchDelay = const Duration(milliseconds: 20);
      engine.resultsByTeam[Side.white] = scripted(best: '(d2d4,pass)');
      engine.searchStarted = Completer<void>();

      final running = controller.compareScenarios();
      await engine.searchStarted!.future;
      controller.playMove(
        BughouseBoard.a,
        NormalMove(from: Square.e2, to: Square.e4),
      );
      await running;

      // The table would otherwise have described the position we left, with a
      // first row cut short by the stop that the move sent.
      expect(controller.scenarios, isEmpty);
    });
  });

  group('a broken engine', () {
    test('is reported once rather than retried in a loop', () async {
      engine.failNextSearch = BughouseEngineFailure('network would not load');
      controller.startAnalysis();
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.error, contains('network would not load'));
      expect(controller.analysisEnabled, isFalse);
      final settled = engine.searches.length;
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(engine.searches.length, settled, reason: 'it stopped, once');
    });
  });
}
