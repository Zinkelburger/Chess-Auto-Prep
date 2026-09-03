/// What the panel and the boards make of a search result.
///
/// The three things covered here are the three that used to be invisible or
/// wrong on screen: the engine's answer had no arrows, its line was never
/// shown at all (its `pv` is board-prefixed UCI, which is unreadable), and its
/// memory and batch settings had nowhere to come from.
library;

import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_controller.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_engine_settings.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/models/board_annotation.dart';
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

  /// Lets the pump run until both teams have an answer folded in.
  ///
  /// Waiting on the *search count* is not enough: the second search is
  /// recorded the moment it starts, so a test that stops there sees the second
  /// team's result still in flight.
  Future<void> settle() async {
    controller.startAnalysis();
    for (
      var i = 0;
      i < 200 &&
          (controller.ours.best == null || controller.theirs.best == null);
      i++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('arrows', () {
    test('draws our best in green and theirs in red, one per board', () async {
      engine.resultsByTeam[Side.white] = scripted(best: '(e2e4,pass)');
      engine.resultsByTeam[Side.black] = scripted(best: '(pass,d2d4)');
      await settle();

      final one = controller.annotationsFor(BughouseBoard.a);
      expect(one, [
        const BoardAnnotation(
          orig: 'e2',
          dest: 'e4',
          brush: AnnotationBrush.green,
        ),
      ]);

      // Board 2 is where the other team's half lands, and it is theirs.
      final two = controller.annotationsFor(BughouseBoard.b);
      expect(two, [
        const BoardAnnotation(
          orig: 'd2',
          dest: 'd4',
          brush: AnnotationBrush.red,
        ),
      ]);
    });

    test('a drop is a badged ring, because it has no square to come from', () {
      // A white pawn in board 1's reserve, and the drop the engine wants.
      controller.loadDualFen(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[P] w KQkq - 0 1'
        '|rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1',
      );
      controller.hoverAction(BughouseJointMove.tryParse('(P@e3,pass)'));

      expect(controller.annotationsFor(BughouseBoard.a), [
        const BoardAnnotation(
          orig: 'e3',
          brush: AnnotationBrush.blue,
          label: 'P',
        ),
      ]);
    });

    test(
      'a hovered line takes both boards from the standing answers',
      () async {
        engine.resultsByTeam[Side.white] = scripted(best: '(e2e4,pass)');
        engine.resultsByTeam[Side.black] = scripted(best: '(pass,d2d4)');
        await settle();

        controller.hoverAction(BughouseJointMove.tryParse('(g1f3,d2d4)'));

        expect(controller.annotationsFor(BughouseBoard.a), [
          const BoardAnnotation(
            orig: 'g1',
            dest: 'f3',
            brush: AnnotationBrush.blue,
          ),
        ], reason: 'the hovered line, not our best');
        expect(controller.annotationsFor(BughouseBoard.b), [
          const BoardAnnotation(
            orig: 'd2',
            dest: 'd4',
            brush: AnnotationBrush.blue,
          ),
        ]);
      },
    );

    test('a hovered move deep in a line is drawn from its own position', () {
      // 1.e4 on board 1, then Black's e5 — a move that is not legal on the
      // position on screen, where e5 is not yet reachable.
      final line = BughouseInfo(
        depth: 6,
        scoreCp: 0,
        nodes: 900,
        nps: 300,
        timeMs: 2000,
        pv: [
          BughouseJointMove.tryParse('(e2e4,pass)')!,
          BughouseJointMove.tryParse('(e7e5,d2d4)')!,
        ],
      );
      final steps = controller.describePv(line, team: Side.white);
      expect(steps, hasLength(2));

      controller.hoverStep(steps[1], owner: 'row');

      expect(controller.annotationsFor(BughouseBoard.a), [
        const BoardAnnotation(
          orig: 'e7',
          dest: 'e5',
          brush: AnnotationBrush.blue,
        ),
      ], reason: 'parsed against the position after 1.e4, not the start');
      expect(controller.annotationsFor(BughouseBoard.b), [
        const BoardAnnotation(
          orig: 'd2',
          dest: 'd4',
          brush: AnnotationBrush.blue,
        ),
      ]);
    });

    test('a row clears only the highlight it owns', () {
      final action = BughouseJointMove.tryParse('(g1f3,pass)')!;
      controller.hoverAction(action, owner: 'first');
      controller.clearHover('second');
      expect(controller.hover.value, isNotNull, reason: 'not its to clear');
      controller.clearHover('first');
      expect(controller.hover.value, isNull);
    });

    test('hovering never rebuilds the pane, only the boards', () {
      var notified = 0;
      controller.addListener(() => notified++);
      controller.hoverAction(BughouseJointMove.tryParse('(g1f3,pass)'));
      controller.hoverAction(null);
      expect(notified, 0);
    });

    test('a move played drops the highlight — the position it lit is gone', () {
      controller.hoverAction(BughouseJointMove.tryParse('(g1f3,pass)'));
      controller.playMove(
        BughouseBoard.a,
        const NormalMove(from: Square.e2, to: Square.e4),
      );
      expect(controller.hover.value, isNull);
    });

    test('the editor draws none: there is no search to illustrate', () async {
      engine.resultsByTeam[Side.white] = scripted(best: '(e2e4,pass)');
      await settle();
      controller.setMode(BughouseMode.setup);
      expect(controller.annotationsFor(BughouseBoard.a), isEmpty);
    });
  });

  group('the engine line, in SAN', () {
    /// The engine's `pv` is a list of joint actions; this is what a real one
    /// looks like once parsed.
    BughouseInfo lineOf(List<String> actions) => BughouseInfo(
      depth: 6,
      scoreCp: -230,
      nodes: 900,
      nps: 300,
      timeMs: 2000,
      pv: [for (final a in actions) BughouseJointMove.tryParse(a)!],
    );

    test('replays the whole variation, and the teams alternate down it', () {
      // From the start on both boards, White is on move everywhere. So our
      // team (White on board 1, Black on board 2) owns only board 1's move,
      // and the opponents own board 2's — the second ply is theirs.
      final steps = controller.describePv(
        lineOf(['(e2e4,pass)', '(e7e5,d2d4)']),
        team: Side.white,
      );

      expect(steps, hasLength(2));
      expect(steps[0].team, Side.white);
      expect(steps[0].seats, 'A + C');
      expect(steps[0].onA, 'e4');

      expect(steps[1].team, Side.black, reason: 'the other team answers');
      expect(steps[1].seats, 'B + D');
      expect(steps[1].onA, 'e5');
      expect(steps[1].onB, 'd4');
    });

    test('an absent seat prints nothing, a deliberate sit prints "sit"', () {
      final steps = controller.describePv(
        lineOf(['(e2e4,pass)']),
        team: Side.white,
      );
      expect(steps.single.onA, 'e4');
      // White is on move on board 2 as well, and White there is the *other*
      // team — so this half was never our decision and prints as nothing.
      expect(steps.single.onB, isNull);

      // Board 2 with Black to move is our partner's, and passing there is a
      // decision our team took.
      controller.loadDualFen(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1'
        '|rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] b KQkq - 0 1',
      );
      final sitting = controller.describePv(
        lineOf(['(e2e4,pass)']),
        team: Side.white,
      );
      expect(sitting.single.onB, 'sit');
    });

    test('stops at the first half that will not play here', () {
      // `d2d4` is not legal on board 1 a move later: White has moved, and it
      // is Black's turn there.
      final steps = controller.describePv(
        lineOf(['(e2e4,pass)', '(d2d4,pass)']),
        team: Side.white,
      );
      expect(steps, hasLength(1));
    });
  });

  group('playing a line', () {
    BughouseInfo lineOf(List<String> actions) => BughouseInfo(
      depth: 6,
      scoreCp: 0,
      nodes: 900,
      nps: 300,
      timeMs: 2000,
      pv: [for (final a in actions) BughouseJointMove.tryParse(a)!],
    );

    test('clicking a move plays the line through it, on both boards', () {
      final steps = controller.describePv(
        lineOf(['(e2e4,pass)', '(e7e5,d2d4)', '(g1f3,pass)']),
        team: Side.white,
      );
      controller.playLine(steps, throughPly: 1);

      // Three half-moves landed: e4, then e5 on board 1 and d4 on board 2.
      expect(controller.history.length, 3);
      expect(controller.history.movetextFor(BughouseBoard.a), '1. e4 e5');
      expect(controller.history.movetextFor(BughouseBoard.b), '1. d4');
      // The third ply was not asked for.
      expect(controller.state.boardA.turn, Side.white);
    });

    test('clicking the row plays just its candidate', () {
      final steps = controller.describePv(
        lineOf(['(e2e4,pass)', '(e7e5,d2d4)']),
        team: Side.white,
      );
      controller.playLine(steps, throughPly: 0);
      expect(controller.history.length, 1);
      expect(controller.history.movetextFor(BughouseBoard.a), '1. e4');
    });

    test('a line that no longer fits stops where it stops', () {
      final steps = controller.describePv(
        lineOf(['(e2e4,pass)', '(e7e5,d2d4)']),
        team: Side.white,
      );
      // The position moves on under the line before it is clicked.
      controller.playMove(
        BughouseBoard.a,
        const NormalMove(from: Square.d2, to: Square.d4),
      );
      controller.playLine(steps, throughPly: 1);
      expect(controller.history.length, 1, reason: 'e4 is not legal now');
      expect(controller.error, isNotNull);
    });
  });

  group('engine settings', () {
    test(
      'are pushed to the process once, then only when they change',
      () async {
        await settle();
        expect(
          engine.options.map((o) => o.name),
          containsAll(<String>['Hash', 'BatchSize']),
        );

        final sent = engine.options.length;
        // Another pass must not re-send what has not changed.
        for (var i = 0; i < 20 && engine.searches.length < 4; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(engine.options.length, sent);

        controller.setEngineSettings(
          controller.engineSettings.copyWith(hashMb: 1024),
        );
        for (var i = 0; i < 40 && engine.options.length == sent; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(engine.options.where((o) => o.name == 'Hash').last.value, 1024);
      },
    );

    test('the line count is what MultiPV asks for', () async {
      controller.setEngineSettings(
        controller.engineSettings.copyWith(lines: 5),
      );
      await settle();
      expect(engine.configurations.last.multiPv, 5);
    });

    test('a stored value that is no longer offered falls back', () {
      // Written by an older build: a dropdown with no matching item throws.
      expect(BughouseEngineSettings.hashChoices, contains(256));
      expect(BughouseEngineSettings.hashChoices, isNot(contains(17)));
    });
  });

  group('a search that has been superseded', () {
    test('its late info lines are not folded into the new position', () async {
      engine.resultsByTeam[Side.white] = scripted(best: '(e2e4,pass)');
      engine.resultsByTeam[Side.black] = scripted(best: '(pass,d2d4)');
      await settle();
      expect(controller.ours.latest, isNotNull);

      // 1.e4 leaves both seats to the other team: Black to move on board 1,
      // White (their seat) to move on board 2.
      controller.playMove(
        BughouseBoard.a,
        const NormalMove(from: Square.e2, to: Square.e4),
      );
      expect(controller.state.hasMoveFor(Side.white), isFalse);
      expect(controller.ours.latest, isNull, reason: 'the move cleared it');

      // Hivemind keeps printing for a moment after `stop`. That line belongs
      // to a position that is gone.
      engine.emit(
        const BughouseInfo(
          depth: 9,
          scoreCp: -100,
          nodes: 5000,
          nps: 900,
          timeMs: 3000,
          pv: [],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        controller.ours.latest,
        isNull,
        reason: 'a score for a team with nothing to move is not a score',
      );
      // And so the headline eval is honestly marked as the opponents'.
      expect(controller.eval?.borrowed, anyOf(isNull, isTrue));
    });
  });

  group('the last move on each board', () {
    test('is that board\'s own, not the line\'s', () {
      controller.playMove(
        BughouseBoard.a,
        const NormalMove(from: Square.e2, to: Square.e4),
      );
      controller.playMove(
        BughouseBoard.b,
        const NormalMove(from: Square.d2, to: Square.d4),
      );

      expect(controller.lastPlyOn(BughouseBoard.a)?.san, 'e4');
      expect(controller.lastPlyOn(BughouseBoard.b)?.san, 'd4');
      // Stepping back is per-cursor, so board 2's last move goes away first.
      controller.back();
      expect(controller.lastPlyOn(BughouseBoard.b), isNull);
      expect(controller.lastPlyOn(BughouseBoard.a)?.san, 'e4');
    });
  });
}
