import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_controller.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_history.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:chess_auto_prep/features/bughouse/widgets/bughouse_move_list.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two boards, two move lists — the FICS arrangement — and a score that says
/// what it means.
void main() {
  /// 1.e4 Nf6 2.e5 Nd5 on board A, 1.d4 d5 on board B, entered interleaved so
  /// the entry order and the two board orders genuinely differ.
  BughouseController playedController() {
    final controller = BughouseController();
    controller.playMove(
      BughouseBoard.a,
      NormalMove(from: Square.e2, to: Square.e4),
    );
    controller.playMove(
      BughouseBoard.b,
      NormalMove(from: Square.d2, to: Square.d4),
    );
    controller.playMove(
      BughouseBoard.a,
      NormalMove(from: Square.g8, to: Square.f6),
    );
    controller.playMove(
      BughouseBoard.b,
      NormalMove(from: Square.d7, to: Square.d5),
    );
    controller.playMove(
      BughouseBoard.a,
      NormalMove(from: Square.e4, to: Square.e5),
    );
    controller.playMove(
      BughouseBoard.a,
      NormalMove(from: Square.f6, to: Square.d5),
    );
    return controller;
  }

  group('per-board numbering', () {
    test('a ply counts on its own board, not on the whole line', () {
      final controller = playedController();
      final plies = controller.history.plies;
      expect(plies.length, 6);

      final boardA = plies.where((p) => p.board == BughouseBoard.a).toList();
      final boardB = plies.where((p) => p.board == BughouseBoard.b).toList();

      // Board A: 1. e4 Nf6 2. e5 Nd5 — four plies, two move numbers.
      expect(boardA.map((p) => p.san).toList(), ['e4', 'Nf6', 'e5', 'Nd5']);
      expect(boardA.map((p) => p.moveNumber).toList(), [1, 1, 2, 2]);
      // Board B: 1. d4 d5 — its own numbering, unaffected by A's four plies.
      expect(boardB.map((p) => p.san).toList(), ['d4', 'd5']);
      expect(boardB.map((p) => p.moveNumber).toList(), [1, 1]);

      controller.dispose();
    });

    test('the number label is a movetext prefix', () {
      final controller = playedController();
      final boardA = controller.history.plies
          .where((p) => p.board == BughouseBoard.a)
          .toList();
      expect(boardA[0].numberLabel, '1.');
      expect(boardA[1].numberLabel, '1...');
      expect(boardA[2].numberLabel, '2.');
      expect(boardA[3].numberLabel, '2...');
      expect(boardA.first.side, Side.white);
      expect(boardA[1].side, Side.black);
      controller.dispose();
    });

    test('navigation still walks the line as it was entered', () {
      final controller = playedController();
      // Index 1 is board B's first move even though board A moved first.
      controller.goTo(2);
      expect(controller.history.currentPly!.board, BughouseBoard.b);
      expect(controller.history.currentPly!.san, 'd4');
      controller.dispose();
    });
  });

  group('the move list', () {
    testWidgets('renders one numbered movetext per board', (tester) async {
      final controller = playedController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 380,
              child: BughouseMoveList(controller: controller),
            ),
          ),
        ),
      );

      expect(find.textContaining('Board 1'), findsOneWidget);
      expect(find.textContaining('Board 2'), findsOneWidget);
      // Each board's own numbering, and no global ply index anywhere. A
      // number is printed before white's move only, as movetext does, so both
      // boards show "1." once and only board A reaches "2.".
      expect(find.text('1.'), findsNWidgets(2));
      expect(find.text('2.'), findsOneWidget);
      expect(find.text('1...'), findsNothing);
      expect(find.text('e4'), findsOneWidget);
      expect(find.text('Nd5'), findsOneWidget);
      expect(find.text('d4'), findsOneWidget);
      // The old interleaved form tagged every move with its board.
      expect(find.text('A: e4'), findsNothing);
    });

    testWidgets('an empty line says what to do instead of showing nothing', (
      tester,
    ) async {
      final controller = BughouseController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BughouseMoveList(controller: controller)),
        ),
      );
      expect(find.textContaining('No moves yet'), findsOneWidget);
    });
  });

  group('what a joint action reads as', () {
    test('each half is SAN on its own board, and a pass is "sit"', () {
      final controller = playedController();
      const move = BughouseJointMove(
        BughouseHalfMove.move('d2d4'),
        BughouseHalfMove.pass(),
      );
      expect(controller.describeHalf(BughouseBoard.a, move), 'd4');
      expect(controller.describeHalf(BughouseBoard.b, move), 'sit');
      controller.dispose();
    });

    test(
      'a pass on a board that is not ours is left out, not called "sit"',
      () {
        // Board B is White to move and we are Black there, so the engine has
        // nothing to move on it — every joint action it returns passes there.
        // Printing "B sit" made every result look like a decision to wait.
        final controller = playedController();
        expect(controller.state.isOurTurn(BughouseBoard.a), isTrue);
        expect(controller.state.isOurTurn(BughouseBoard.b), isFalse);
        const move = BughouseJointMove(
          BughouseHalfMove.move('d2d4'),
          BughouseHalfMove.pass(),
        );
        expect(controller.describeJoint(move), 'A d4');
        controller.dispose();
      },
    );

    test('a pass on a board that is ours is a real decision', () {
      final controller = playedController();
      // Give board B back to us: now passing there is the engine choosing to
      // sit, which is the one case worth printing.
      controller.playMove(
        BughouseBoard.b,
        const NormalMove(from: Square.c2, to: Square.c4),
      );
      expect(controller.state.isOurTurn(BughouseBoard.b), isTrue);
      const move = BughouseJointMove(
        BughouseHalfMove.move('d2d4'),
        BughouseHalfMove.pass(),
      );
      expect(controller.describeJoint(move), 'A d4   ·   C sit');
      controller.dispose();
    });

    test('each half is addressed to the person who has to play it', () {
      final controller = playedController();
      // We are White on A, so board A is us and board B is our partner. The
      // opponents' search covers the same two boards from the other side.
      const move = BughouseJointMove(
        BughouseHalfMove.move('d2d4'),
        BughouseHalfMove.move('c2c4'),
      );
      expect(
        controller.describeSeats(move, team: Side.white).map((r) => r.who),
        ['A', 'C'],
      );
      expect(
        controller.describeSeats(move, team: Side.black).map((r) => r.who),
        ['B', 'D'],
      );
      expect(controller.describeMoves(move, team: Side.white), 'd4  ·  c4');
      controller.dispose();
    });

    test('a move that will not parse here falls back to its UCI', () {
      final controller = BughouseController();
      const nonsense = BughouseJointMove(
        BughouseHalfMove.move('h8h1'),
        BughouseHalfMove.pass(),
      );
      expect(controller.describeHalf(BughouseBoard.a, nonsense), 'h8h1');
      controller.dispose();
    });
  });

  group('the score', () {
    BughouseInfo info({int cp = 0, int? mate, int rank = 1}) => BughouseInfo(
      depth: 5,
      scoreCp: cp,
      nodes: 100,
      nps: 10,
      timeMs: 1000,
      multipv: rank,
      mateIn: mate,
      pv: const [],
    );

    test('is printed signed, and a mate is printed as a mate', () {
      expect(info(cp: -230).scoreLabel, '-2.30');
      expect(info(cp: 45).scoreLabel, '+0.45');
      expect(info(mate: 3).scoreLabel, '#3');
      expect(info(mate: -2).scoreLabel, '#-2');
    });

    test('reads level as 0.00, whatever the engine calls it', () {
      // The engine says -2.30 for a dead-level position, which every chess eye
      // reads as losing. What the panel shows is measured against that.
      expect(info(cp: -230).evalLabel, '0.00');
      expect(info(cp: -230).scoreLabel, '-2.30');
      expect(info(cp: -74).evalLabel, '+1.56');
      expect(info(cp: -546).evalLabel, '-3.16');
      expect(info(mate: 3).evalLabel, '#3');
      expect(info(mate: -2).evalLabel, '#-2');
    });

    test('fills the bar from our side, and fills it fully for a mate', () {
      expect(info(cp: -230).barFraction, closeTo(0.5, 0.001));
      expect(info(cp: -74).barFraction, greaterThan(0.6));
      expect(info(cp: -546).barFraction, lessThan(0.25));
      expect(info(mate: 2).barFraction, 1.0);
      expect(info(mate: -2).barFraction, 0.0);
    });

    test('turned around, it describes the other side of the table', () {
      expect(BughouseController.flipEval('+1.56'), '-1.56');
      expect(BughouseController.flipEval('-3.16'), '+3.16');
      expect(BughouseController.flipEval('0.00'), '0.00');
      expect(BughouseController.flipEval('#3'), '#-3');
      expect(BughouseController.flipEval('#-3'), '#3');
    });

    test('is read against a measured baseline, not against zero', () {
      // The opening position reads about -2.30 from either seat, so that is
      // where "level" sits on this scale.
      expect(BughouseInfo.levelBaseline, -2.3);
      expect(info(cp: -230).relativeToLevel, closeTo(0, 0.001));
      expect(info(cp: -74).relativeToLevel, greaterThan(1));
      expect(info(cp: -546).relativeToLevel, lessThan(-3));
    });

    test('only the last state of each ranked line survives a search', () {
      final result = BughouseSearchResult(
        best: BughouseJointMove.tryParse('(d2d4,pass)'),
        ponder: null,
        infos: [
          info(cp: -240, rank: 1),
          info(cp: -230, rank: 1),
          info(cp: -234, rank: 2),
          info(cp: -251, rank: 3),
        ],
      );
      expect(result.lines.map((l) => l.multipv).toList(), [1, 2, 3]);
      expect(result.lines.first.scoreCp, -230);
      expect(result.principal!.multipv, 1);
    });

    test('a search that reported nothing has no lines to show', () {
      const empty = BughouseSearchResult(best: null, ponder: null, infos: []);
      expect(empty.lines, isEmpty);
      expect(empty.principal, isNull);
    });
  });

  group('the engine dialect', () {
    test('a ranked info line carries its rank', () {
      final history = BughouseHistory(BughouseState.initial());
      expect(history.isEmpty, isTrue);
      // `multipv` defaults to 1 so a single-line search needs no special case.
      const single = BughouseInfo(
        depth: 1,
        scoreCp: 0,
        nodes: 1,
        nps: 1,
        timeMs: 1,
        pv: [],
      );
      expect(single.multipv, 1);
      expect(single.mateIn, isNull);
    });
  });
}
