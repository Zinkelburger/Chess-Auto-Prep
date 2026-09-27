import 'package:chess_auto_prep/features/bughouse/models/bughouse_notation.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/models/board_annotation.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// [BughouseNotation] on its own: joint actions read against a position,
/// without a controller or an engine in the way.
void main() {
  BughouseJointMove joint(String text) => BughouseJointMove.tryParse(text)!;

  BughouseInfo pv(List<String> actions) => BughouseInfo(
    depth: 1,
    scoreCp: 0,
    nodes: 10,
    nps: 1,
    timeMs: 1,
    pv: [for (final a in actions) joint(a)],
  );

  final initial = BughouseState.initial();

  group('parseEngineUci', () {
    test('a bare pawn move to the last rank is a queen promotion', () {
      final board = BughouseState.tryParseDualFen(
        'k7/P7/8/8/8/8/8/K7[] w - - 0 1',
      )!.boardA;
      final move = parseEngineUci(board, 'a7a8')! as NormalMove;
      expect(move.promotion, Role.queen);
      // A spelled-out promotion is kept as written.
      expect(
        (parseEngineUci(board, 'a7a8n')! as NormalMove).promotion,
        Role.knight,
      );
    });

    test('drops and nonsense', () {
      expect(parseEngineUci(initial.boardA, 'N@f3'), isA<DropMove>());
      expect(parseEngineUci(initial.boardA, 'nope'), isNull);
    });
  });

  group('describeHalf', () {
    test('SAN on its board, sit for a pass, raw UCI when stale', () {
      final n = BughouseNotation(initial);
      expect(n.describeHalf(BughouseBoard.a, joint('(g1f3,pass)')), 'Nf3');
      expect(n.describeHalf(BughouseBoard.b, joint('(g1f3,pass)')), 'sit');
      expect(n.describeHalf(BughouseBoard.a, joint('(e2e5,pass)')), 'e2e5');
    });
  });

  group('describeSeats', () {
    test('a pass on a board the team is not on move on is not a decision', () {
      final rows = BughouseNotation(
        initial,
      ).describeSeats(joint('(g1f3,pass)'), team: Side.white);
      expect(rows, hasLength(1));
      expect(rows.single.who, 'A');
      expect(rows.single.move, 'Nf3');
      expect(rows.single.board, BughouseBoard.a);
      expect(rows.single.hint, startsWith('A — You'));
    });

    test('a pass where the team is on move reads as sit', () {
      final n = BughouseNotation(initial);
      expect(n.describeJoint(joint('(pass,pass)'), team: Side.white), 'A sit');
      // The black team's seat on board 2 is white, and so on move there.
      expect(n.describeJoint(joint('(pass,pass)'), team: Side.black), 'D sit');
    });

    test('both boards in one line, and just the moves', () {
      final n = BughouseNotation(
        initial.playMove(
          BughouseBoard.b,
          const NormalMove(from: Square.d2, to: Square.d4),
        )!,
      );
      // White on A and black on B belong to the same team.
      final action = joint('(e2e4,d7d5)');
      expect(n.describeJoint(action, team: Side.white), 'A e4   ·   B d5');
      expect(n.describeMoves(action, team: Side.white), 'e4  ·  d5');
    });
  });

  group('describePv', () {
    test('replays the line, alternating teams', () {
      final steps = BughouseNotation(
        initial,
      ).describePv(pv(['(e2e4,pass)', '(e7e5,d2d4)']), team: Side.white);
      expect(steps, hasLength(2));
      expect(steps[0].team, Side.white);
      expect(steps[0].seats, 'A + B');
      expect(steps[0].onA, 'e4');
      expect(steps[0].onB, isNull, reason: 'C is not on move on board 2');
      expect(steps[0].before.dualFen, initial.dualFen);

      expect(steps[1].team, Side.black);
      expect(steps[1].seats, 'C + D');
      expect(steps[1].onA, 'e5');
      expect(steps[1].onB, 'd4');
      expect(steps[1].before.boardA.turn, Side.black);
      expect(steps[1].seatOn(BughouseBoard.b, initial), 'D');
    });

    test('stops at the first half that will not play', () {
      final steps = BughouseNotation(
        initial,
      ).describePv(pv(['(e2e4,pass)', '(e2e4,pass)']), team: Side.white);
      expect(steps, hasLength(1));
    });

    test('an all-pass ply stays with the team that moved last', () {
      final steps = BughouseNotation(initial).describePv(
        pv(['(e2e4,pass)', '(e7e5,pass)', '(pass,pass)']),
        team: Side.white,
      );
      expect(steps, hasLength(3));
      expect(steps[2].team, Side.black);
      expect(steps[2].onA, isNull, reason: 'black is no longer on move on A');
      expect(steps[2].onB, 'sit', reason: 'its board-2 seat is white, on move');
    });

    test('an all-pass ply nobody is on move for ends the line', () {
      final steps = BughouseNotation(
        initial,
      ).describePv(pv(['(e2e4,pass)', '(pass,pass)']), team: Side.white);
      expect(steps, hasLength(1));
    });

    test('respects the ply cap', () {
      final steps = BughouseNotation(initial).describePv(
        pv(['(e2e4,pass)', '(e7e5,pass)', '(g1f3,pass)']),
        team: Side.white,
        maxPlies: 2,
      );
      expect(steps, hasLength(2));
    });
  });

  group('preview and annotate', () {
    test('a preview plays the halves that fit', () {
      final after = BughouseNotation(initial).preview(joint('(e2e4,d7d5)'));
      expect(after.boardA.turn, Side.black);
      expect(after.boardB.turn, Side.white, reason: 'd7d5 is not legal yet');
    });

    test('a move is an arrow and a drop is a badged ring', () {
      final withPocket = BughouseState.tryParseDualFen(
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR[Nn] w KQkq - 0 2',
      )!;
      final n = BughouseNotation(withPocket);
      final arrow = n.annotate(
        BughouseBoard.a,
        joint('(g1f3,pass)'),
        AnnotationBrush.green,
      );
      expect(arrow.single.orig, 'g1');
      expect(arrow.single.dest, 'f3');

      final ring = n.annotate(
        BughouseBoard.a,
        joint('(N@f3,pass)'),
        AnnotationBrush.blue,
      );
      expect(ring.single.orig, 'f3');
      expect(ring.single.dest, isNull);
      expect(ring.single.label, 'N');

      expect(
        n.annotate(BughouseBoard.b, joint('(g1f3,pass)'), AnnotationBrush.blue),
        isEmpty,
      );
      expect(n.annotate(BughouseBoard.a, null, AnnotationBrush.blue), isEmpty);
    });
  });
}
