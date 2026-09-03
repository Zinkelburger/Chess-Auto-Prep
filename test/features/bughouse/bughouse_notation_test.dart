import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_controller.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_eval.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_history.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:chess_auto_prep/features/bughouse/widgets/bughouse_board_card.dart';
import 'package:chess_auto_prep/features/bughouse/widgets/bughouse_move_list.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    Future<void> pumpBoth(WidgetTester tester, BughouseController c) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  for (final which in BughouseBoard.values)
                    SizedBox(
                      width: 380,
                      child: BughouseBoardMovetext(controller: c, which: which),
                    ),
                ],
              ),
            ),
          ),
        );

    testWidgets('renders one numbered movetext per board', (tester) async {
      final controller = playedController();
      addTearDown(controller.dispose);

      await pumpBoth(tester, controller);

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

    testWidgets('a board with no moves says so in its own column', (
      tester,
    ) async {
      final controller = BughouseController();
      addTearDown(controller.dispose);
      await pumpBoth(tester, controller);
      expect(find.textContaining('No moves on this board'), findsNWidgets(2));
    });
  });

  group('copying the moves out', () {
    /// What the platform channel was handed, so a tap can be checked against
    /// the text rather than against the button merely being there.
    String? clipboard;

    setUp(() {
      clipboard = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
    });

    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    test('a board copies as its own game, numbered its own way', () {
      final controller = playedController();
      // Not the entry order, and not a numbering shared with the other board:
      // each column reads as the ordinary game it is.
      expect(
        controller.history.movetextFor(BughouseBoard.a),
        '1. e4 Nf6 2. e5 Nd5',
      );
      expect(controller.history.movetextFor(BughouseBoard.b), '1. d4 d5');
      controller.dispose();
    });

    test('a board whose line opens with black says so', () {
      final controller = BughouseController();
      addTearDown(controller.dispose);
      // Board 2 is loaded a move in, so its first *recorded* ply is black's —
      // the case a bare "number before white only" rule prints unlabelled.
      controller.loadDualFen(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1|'
        'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR[] b KQkq - 0 1',
      );
      controller.playMove(
        BughouseBoard.b,
        const NormalMove(from: Square.d7, to: Square.d5),
      );
      expect(controller.history.movetextFor(BughouseBoard.b), '1... d5');
    });

    test('the table copies as two named lines, never interleaved', () {
      final controller = playedController();
      expect(
        controller.history.tableMovetext,
        'Board 1: 1. e4 Nf6 2. e5 Nd5\nBoard 2: 1. d4 d5',
      );
      controller.dispose();
    });

    test('an empty board is still named, so the shape does not change', () {
      final controller = BughouseController();
      addTearDown(controller.dispose);
      expect(controller.history.tableMovetext, 'Board 1:\nBoard 2:');
    });

    testWidgets("a board's header copies that board and nothing else", (
      tester,
    ) async {
      final controller = playedController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 420,
                child: BughouseBoardCard(
                  controller: controller,
                  which: BughouseBoard.b,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip("Copy board 2's moves"));
      await tester.pump();
      expect(clipboard, '1. d4 d5');
    });

    testWidgets('the button is disabled while that board is empty', (
      tester,
    ) async {
      final controller = BughouseController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 420,
                child: BughouseBoardCard(
                  controller: controller,
                  which: BughouseBoard.a,
                ),
              ),
            ),
          ),
        ),
      );

      // Present, so the flip button beside it never shifts sideways when the
      // first move is played, but dead until there is something to copy.
      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.copy),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('the strip under both boards copies the pair', (tester) async {
      final controller = playedController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BughouseLineControls(controller: controller)),
        ),
      );

      await tester.tap(find.byTooltip('Copy the table'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Both boards' moves"));
      await tester.pumpAndSettle();
      expect(clipboard, contains('Board 1: 1. e4 Nf6 2. e5 Nd5'));
      expect(clipboard, contains('Board 2: 1. d4 d5'));

      await tester.tap(find.byTooltip('Copy the table'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dual FEN'));
      await tester.pumpAndSettle();
      // One string, two positions, and the position the boards are showing.
      expect(clipboard, controller.state.dualFen);
      expect(clipboard, contains('|'));
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
    BughouseInfo info({
      int cp = 0,
      int? mate,
      int rank = 1,
      bool ahead = false,
    }) => BughouseInfo(
      depth: 5,
      scoreCp: cp,
      nodes: 100,
      nps: 10,
      timeMs: 1000,
      multipv: rank,
      mateIn: mate,
      hadTimeAdvantage: ahead,
      pv: const [],
    );

    test('is printed signed, and a mate is printed as a mate', () {
      expect(info(cp: -230).scoreLabel, '-2.30');
      expect(info(cp: 45).scoreLabel, '+0.45');
      expect(info(mate: 3).scoreLabel, '#3');
      expect(info(mate: -2).scoreLabel, '#-2');
    });

    test('inverts the engine\'s tangent exactly', () {
      // Hivemind reports `180*tan(1.56*Q)`, so the tangent comes back out
      // without a fitted constant. -230 is what a balanced position reads
      // when neither team may sit.
      expect(info(cp: 0).q, closeTo(0, 1e-9));
      expect(info(cp: -230).q, closeTo(-0.5814, 0.001));
      expect(info(cp: 230).q, closeTo(0.5814, 0.001));
    });
  });

  group('the offset in a raw score', () {
    BughouseInfo line(int cp, {int? mate}) => BughouseInfo(
      depth: 5,
      scoreCp: cp,
      nodes: 100,
      nps: 10,
      timeMs: 1000,
      mateIn: mate,
      pv: const [],
    );

    test('is measured from the two teams, not assumed', () {
      // Both teams searching the same position report `±advantage + offset`,
      // so the pair gives both without a constant. Measured numbers: a
      // symmetric Italian on both boards, where the true value is 0.
      final calibration = BughouseCalibration.measure(line(-307), line(-320))!;
      expect(calibration.source, BughouseCalibrationSource.measured);
      expect(calibration.offsetQ, closeTo(-0.672, 0.005));
      expect(
        BughouseEval.of(line(-307), calibration).advantage,
        closeTo(0, 0.01),
        reason: 'a position symmetric on both boards is exactly level',
      );
    });

    test('is not the same number in every position', () {
      // Three exactly symmetric two-board positions, all of them dead equal
      // by construction, as the engine actually scored them. The offset is
      // the network's estimate of what the clock advantage is worth *here*,
      // so it is large in the opening and small in a bare endgame — which is
      // why one fixed constant read a drawn K+P ending as more than a pawn up.
      for (final (ours, theirs) in [
        (-229, -222), // the opening
        (-307, -320), // a symmetric Italian
        (-93, -117), // a mirrored king-and-pawn ending
      ]) {
        final calibration = BughouseCalibration.measure(
          line(ours),
          line(theirs),
        )!;
        expect(
          BughouseEval.of(line(ours), calibration).advantage,
          closeTo(0, 0.05),
        );
      }
      // And the offsets themselves are nowhere near each other.
      expect(
        BughouseCalibration.measure(line(-229), line(-222))!.offsetQ,
        closeTo(-0.575, 0.01),
      );
      expect(
        BughouseCalibration.measure(line(-93), line(-117))!.offsetQ,
        closeTo(-0.337, 0.01),
      );
    });

    test('a mate score carries no value to calibrate with', () {
      expect(BughouseCalibration.measure(line(0, mate: 3), line(-230)), isNull);
      expect(BughouseCalibration.measure(line(-230), null), isNull);
    });

    test('the assumed offset follows who may sit, not a constant', () {
      // The network reads its own `TimeAdvantage` bit as about ±0.58 of Q, and
      // the offset is the average of the two teams' readings. So it is -0.58
      // when neither may sit and zero when exactly one may — which is why
      // subtracting one fixed number mis-read every "we may sit" search.
      expect(
        BughouseCalibration.assumed(weMaySit: false, theyMaySit: false).offsetQ,
        closeTo(-0.5814, 0.001),
      );
      expect(
        BughouseCalibration.assumed(weMaySit: true, theyMaySit: false).offsetQ,
        closeTo(0, 0.001),
      );
      expect(
        BughouseCalibration.assumed(weMaySit: false, theyMaySit: true).offsetQ,
        closeTo(0, 0.001),
      );
    });

    test('a queen is worth the same whichever stance we searched', () {
      // Four measured scores: the opening and the same position a queen up on
      // board 1, each searched with the team told it may not sit and told it
      // may. What a queen is worth cannot depend on which of those we asked.
      const startLevel = -233, queenLevel = -139;
      const startAhead = 236, queenAhead = 367;

      double gainIn(BughouseCalibration c, int before, int after) =>
          BughouseEval.of(line(after), c).advantage -
          BughouseEval.of(line(before), c).advantage;

      final level = gainIn(
        BughouseCalibration.assumed(weMaySit: false, theyMaySit: false),
        startLevel,
        queenLevel,
      );
      final ahead = gainIn(
        BughouseCalibration.assumed(weMaySit: true, theyMaySit: false),
        startAhead,
        queenAhead,
      );
      expect(level, closeTo(0.16, 0.01));
      expect(ahead, closeTo(0.13, 0.01));
      expect(
        (level - ahead).abs(),
        lessThan(0.05),
        reason: 'the engine moved by the same amount in both',
      );

      // Taking the offset out of the raw score instead — a subtraction in the
      // engine's own tangent space rather than in the value it is a tangent
      // of — inflates both, and by different amounts, so the same queen reads
      // half a pawn bigger under one stance than the other.
      double rawGain(double baseline, int before, int after) =>
          (after / 100 - baseline) - (before / 100 - baseline);
      expect(rawGain(-2.30, startLevel, queenLevel), closeTo(0.94, 0.01));
      expect(rawGain(2.30, startAhead, queenAhead), closeTo(1.31, 0.01));
    });
  });

  group('an evaluation', () {
    BughouseEval eval(double advantage, {int? mate}) => BughouseEval(
      advantage: advantage,
      mateIn: mate,
      source: BughouseCalibrationSource.measured,
    );

    test('prints level as 0.00 and a mate as a mate', () {
      expect(eval(0).label, '0.00');
      expect(eval(0.5).label, '+1.78');
      expect(eval(-0.5).label, '-1.78');
      expect(eval(0, mate: 3).label, '#3');
      expect(eval(0, mate: -2).label, '#-2');
    });

    test('is symmetric: the same swing reads the same size either way', () {
      // The piecewise map this replaces was anchored on a level point of
      // -0.58, so a queen up read +5% and a queen down -16%.
      expect(eval(0).winPercent, 50);
      expect(eval(0.15).winPercent, closeTo(57.5, 0.01));
      expect(eval(-0.15).winPercent, closeTo(42.5, 0.01));
      expect(eval(0).winLabel, '50%');
      expect(eval(0, mate: 2).winPercent, 100.0);
      expect(eval(0, mate: -2).winPercent, 0.0);
    });

    test('the number and the percentage cannot disagree', () {
      // Both are read off `advantage`, so a positive one is a positive other.
      for (final advantage in [-0.9, -0.4, -0.05, 0.0, 0.05, 0.4, 0.9]) {
        final e = eval(advantage);
        expect(e.score.sign, advantage.sign);
        expect(e.winPercent > 50, advantage > 0);
      }
    });

    test('moves the same way the engine\'s value does', () {
      var previous = -1.0;
      for (final advantage in [-0.9, -0.5, -0.2, 0.0, 0.2, 0.5, 0.9]) {
        final percent = eval(advantage).winPercent;
        expect(percent, greaterThan(previous));
        previous = percent;
      }
    });

    test('turned around, it describes the other side of the table', () {
      expect(eval(0.4).flipped.label, eval(-0.4).label);
      expect(
        eval(0.4).flipped.winPercent,
        closeTo(100 - eval(0.4).winPercent, 1e-9),
      );
      expect(eval(0, mate: 3).flipped.label, '#-3');
      expect(eval(0, mate: -3).flipped.label, '#3');
      expect(eval(0).flipped.label, '0.00');
    });

    test('a runaway value still prints a number', () {
      // The tangent goes to infinity at ±1, and a won position is a mate long
      // before it gets there.
      expect(eval(1.0).label, eval(0.9).label);
      expect(eval(1.0).winPercent, 100);
      expect(eval(-1.0).winPercent, 0);
    });
  });

  group('a search result', () {
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

    test('the shortlist is ordered by score, not by the engine\'s rank', () {
      // Hivemind ranks MultiPV by visit count. This is a block we actually
      // measured: rank 3 scores better than rank 2, so presenting the engine's
      // order as "best first" contradicts the numbers printed beside it.
      final result = BughouseSearchResult(
        best: null,
        ponder: null,
        infos: [
          info(cp: 8, rank: 1),
          info(cp: -61, rank: 2),
          info(cp: -38, rank: 3),
          info(cp: -46, rank: 4),
        ],
      );
      expect(result.lines.map((l) => l.multipv).toList(), [1, 3, 4, 2]);
      // Rank 1 stays pinned: it is the line `bestmove` is aligned with.
      expect(result.lines.first.multipv, 1);
    });

    test('a mate outranks every score, in the direction it points', () {
      final ours = BughouseSearchResult(
        best: null,
        ponder: null,
        infos: [
          info(cp: 8, rank: 1),
          info(cp: 400, rank: 2),
          info(mate: 3, rank: 3),
        ],
      );
      expect(ours.lines.map((l) => l.multipv).toList(), [1, 3, 2]);

      final theirs = BughouseSearchResult(
        best: null,
        ponder: null,
        infos: [
          info(cp: 8, rank: 1),
          info(mate: -2, rank: 2),
          info(cp: -900, rank: 3),
        ],
      );
      expect(theirs.lines.map((l) => l.multipv).toList(), [1, 3, 2]);
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
