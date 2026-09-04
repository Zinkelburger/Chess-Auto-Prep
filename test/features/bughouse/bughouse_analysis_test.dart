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
import 'package:chess_auto_prep/features/bughouse/models/bughouse_eval.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bughouse_engine.dart';

BughouseInfo _line(int cp) => BughouseInfo(
  depth: 5,
  scoreCp: cp,
  nodes: 100,
  nps: 10,
  timeMs: 1000,
  pv: const [],
);

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

  /// The same, but waits for both teams' *results* rather than for the second
  /// search to have started. Anything about the eval needs the pair, because
  /// the offset is measured from it.
  Future<void> settleBoth() async {
    controller.startAnalysis();
    for (
      var i = 0;
      i < 200 &&
          (controller.ours.principal == null ||
              controller.theirs.principal == null);
      i++
    ) {
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
          const NormalMove(from: Square.e2, to: Square.e4),
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));

        // The result belonged to the position before the move, so it is gone.
        expect(controller.ours.latest?.scoreCp, isNot(-100));
      },
    );
  });

  group('the eval', () {
    test('takes its zero from both teams, not from a constant', () async {
      // A symmetric Italian on both boards, as the engine actually scored it:
      // -3.07 from our seat and -3.20 from theirs. The position is exactly
      // level by construction, and only the pair says so — a fixed -2.30
      // baseline read it as most of a pawn against us.
      engine.resultsByTeam[Side.white] = scripted(
        best: '(b1c3,pass)',
        cp: -307,
      );
      engine.resultsByTeam[Side.black] = scripted(
        best: '(b8c6,pass)',
        cp: -320,
      );
      await settleBoth();

      expect(controller.calibration.source, BughouseCalibrationSource.measured);
      expect(controller.eval!.advantage, closeTo(0, 0.02));
      expect(controller.eval!.winPercent, closeTo(50, 1));
      expect(controller.eval!.borrowed, isFalse);
    });

    test('a drawn ending is not a pawn up', () async {
      // A mirrored king-and-pawn ending: -0.93 and -1.17, dead drawn. The
      // offset here is half what it is in the opening, because what the
      // network is really reporting is what the clock advantage is worth in
      // this position.
      engine.resultsByTeam[Side.white] = scripted(best: '(e2f2,pass)', cp: -93);
      engine.resultsByTeam[Side.black] = scripted(
        best: '(e7f7,pass)',
        cp: -117,
      );
      await settleBoth();

      expect(controller.calibration.offsetQ, closeTo(-0.337, 0.01));
      expect(controller.eval!.advantage, closeTo(0, 0.05));
      expect(
        controller.eval!.winPercent,
        closeTo(50, 3),
        reason: 'one fixed baseline read this as a pawn and a third up',
      );
    });

    test('a queen up reads as an advantage, and a queen down as a loss', () {
      // -1.39 from our seat, -3.46 from theirs, white a queen up on board 1.
      final calibration = BughouseCalibration.measure(
        _line(-139),
        _line(-346),
      )!;
      final us = BughouseEval.of(_line(-139), calibration);
      expect(us.advantage, closeTo(0.14, 0.01));
      expect(us.winPercent, greaterThan(55));
      expect(us.flipped.winPercent, closeTo(100 - us.winPercent, 1e-9));
    });

    test('a "we may sit" search reads level too, not +4.7', () async {
      controller.setTimeStance(BughouseTimeStance.ahead);
      // The level opening once we are told the team may sit: +2.36 from our
      // seat, and the opponents — who may not — still read -2.33. The two
      // agree, so the offset is zero and what is left is the clock advantage
      // itself, which is what being up on the diagonal is actually worth.
      engine.resultsByTeam[Side.white] = scripted(
        best: '(pass,pass)',
        cp: 236,
        hadTimeAdvantage: true,
      );
      engine.resultsByTeam[Side.black] = scripted(
        best: '(d7d5,pass)',
        cp: -233,
      );
      await settleBoth();

      expect(controller.calibration.offsetQ, closeTo(0, 0.02));
      expect(controller.eval!.winPercent, greaterThan(70));
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

      // Only the team with a move was asked — the engine answers a team with
      // nothing to move with no score at all, so there is no pair to be had.
      expect(engine.configurations.map((c) => c.team).toSet(), {Side.black});
      final eval = controller.eval!;
      expect(eval.borrowed, isTrue);
      // Their search, read from our seat: they are better, so we are worse.
      expect(eval.advantage, lessThan(0));
      expect(eval.winPercent, lessThan(50));
    });

    test(
      'the offset survives a move, so a borrowed eval still has one',
      () async {
        engine.resultsByTeam[Side.white] = scripted(
          best: '(b1c3,pass)',
          cp: -307,
        );
        engine.resultsByTeam[Side.black] = scripted(
          best: '(b8c6,pass)',
          cp: -320,
        );
        await settleBoth();
        final measured = controller.calibration.offsetQ;

        controller.playMove(
          BughouseBoard.a,
          const NormalMove(from: Square.e2, to: Square.e4),
        );
        expect(controller.calibration.offsetQ, measured);
        expect(
          controller.calibration.source,
          BughouseCalibrationSource.carried,
        );
      },
    );

    test('a change of the rules drops it, because the pair changes', () async {
      engine.resultsByTeam[Side.white] = scripted(
        best: '(b1c3,pass)',
        cp: -307,
      );
      engine.resultsByTeam[Side.black] = scripted(
        best: '(b8c6,pass)',
        cp: -320,
      );
      await settleBoth();
      expect(controller.calibration.source, BughouseCalibrationSource.measured);

      controller.setTimeStance(BughouseTimeStance.ahead);
      expect(controller.calibration.source, BughouseCalibrationSource.assumed);
      // Exactly one team may sit, so the two readings cancel: the offset is
      // zero and the clock advantage stays in the number.
      expect(controller.calibration.offsetQ, closeTo(0, 0.001));
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
      'searches both teams per row, and measures each row\'s own zero',
      () async {
        await settleBoth();
        engine.resultsByTeam[Side.white] = scripted(
          best: '(d2d4,pass)',
          cp: -230,
        );
        engine.resultsByTeam[Side.black] = scripted(
          best: '(d7d5,pass)',
          cp: -222,
        );

        await controller.compareScenarios();

        expect(controller.scenarios, hasLength(3));
        // Three rows, two searches each: ours under the row's stance, theirs
        // under the complementary one. A row whose offset came from anywhere
        // but its own pair is not comparable with the others, which is the
        // whole point of the table.
        final runs = engine.configurations.sublist(
          engine.configurations.length - 6,
        );
        expect(runs.map((c) => c.team).toList(), [
          Side.white,
          Side.black,
          Side.white,
          Side.black,
          Side.white,
          Side.black,
        ]);
        expect(runs.map((c) => c.hasTimeAdvantage).toList(), [
          true,
          false,
          false,
          false,
          false,
          false,
        ]);
        // The constraint is ours to obey; the opponents are not bound by it.
        expect(runs.map((c) => c.requireMoveOn).toList(), [
          RequireMoveOn.none,
          RequireMoveOn.none,
          RequireMoveOn.none,
          RequireMoveOn.none,
          RequireMoveOn.boardA,
          RequireMoveOn.none,
        ]);
        for (final row in controller.scenarios) {
          expect(row.calibration.source, BughouseCalibrationSource.measured);
          expect(row.eval, isNotNull);
        }
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
        const NormalMove(from: Square.e2, to: Square.e4),
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
