import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/search_table.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _board = Fen('r4rk1/pppbqppp/2n5/8/3N4/2N5/PPP2PPP/R2QR1K1 b - - 2 13');

MoveRef _move(String san) => MoveRef(uci: san.toLowerCase(), san: san);

/// A searched leaf worth [cp] to the side the tree is for.
SearchNode _worth(String name, int cp) =>
    HorizonNode(fen: Fen(name), evalForUs: Eval(cp));

void main() {
  // Black to move. Searched for Black, the board is Black's choice of the
  // engine's best; searched for White, it is the replies Maia expects.
  final forBlack = OurNode.over(
    fen: _board,
    evalForUs: const Eval(0),
    candidates: [
      CandidateMove(move: _move('Qf6'), child: _worth('after Qf6', -10)),
      CandidateMove(move: _move('Qb4'), child: _worth('after Qb4', 20)),
      CandidateMove(
        move: _move('Qc5'),
        child: const FrontierNode(fen: Fen('after Qc5'), evalForUs: Eval(-30)),
      ),
    ],
  );
  final forWhite = OpponentNode.over(
    fen: _board,
    evalForUs: const Eval(0),
    replies: [
      // The engine has Qb4 as fine for Black, and White's search finds
      // White a pawn and a half up after it.
      ReplyMove(
        move: _move('Qb4'),
        probability: 0.25,
        child: OurNode.over(
          fen: const Fen('after Qb4'),
          evalForUs: const Eval(-20),
          candidates: [
            CandidateMove(move: _move('Nd5'), child: _worth('deeper', 150)),
          ],
        ),
      ),
      ReplyMove(
        move: _move('Qf6'),
        probability: 0.6,
        child: _worth('after Qf6', 10),
      ),
      ReplyMove(
        move: _move('Qd6'),
        probability: 0.15,
        child: _worth('after Qd6', 90),
      ),
    ],
  );

  group('searchRows', () {
    test('at our move: our candidates best first with both sides\' values, '
        'then the moves only the model expects', () {
      final rows = searchRows(
        side: Side.black,
        mine: forBlack,
        other: forWhite,
      );
      expect([for (final r in rows) r.move.san], ['Qb4', 'Qf6', 'Qc5', 'Qd6']);
      final qb4 = rows[0];
      // Black's search is worth +20 to Black here: under a half for White.
      expect(qb4.black!.forWhite, lessThan(0.5));
      expect(qb4.black!.searched, isTrue);
      // White's search has White well ahead after the same move.
      expect(qb4.white!.forWhite, greaterThan(0.6));
      expect(qb4.share, 0.25);
      expect(qb4.engineCp, -20, reason: 'from White\'s side');
      expect(qb4.trap, isFalse, reason: 'our own move is never a trap');
      final qc5 = rows[2];
      expect(qc5.black!.searched, isFalse, reason: 'not expanded yet');
      expect(qc5.white, isNull, reason: 'the model did not expect it');
      expect(qc5.share, isNull);
      final qd6 = rows[3];
      expect(qd6.black, isNull, reason: 'not among the engine\'s best');
      expect(qd6.engineCp, 90);
    });

    test('at their reply: most played first, traps marked, then our '
        'search\'s other moves', () {
      final rows = searchRows(
        side: Side.white,
        mine: forWhite,
        other: forBlack,
      );
      expect([for (final r in rows) r.move.san], ['Qf6', 'Qb4', 'Qd6', 'Qc5']);
      // Qd6 loses 1.1 against Qb4 but is played 15%, under the fifth a
      // trap needs: the Positions' rule, the table's too.
      expect([for (final r in rows) r.trap], [false, false, false, false]);
      expect(rows[1].engineCp, -20, reason: 'one score, either way up');
      expect(rows[0].share, 0.6);
    });

    test('a reply played a fifth of the time or more that loses half a '
        'pawn against their best is a trap, with what it loses', () {
      final often = OpponentNode.over(
        fen: _board,
        evalForUs: const Eval(0),
        replies: [
          for (final reply in forWhite.replies)
            ReplyMove(
              move: reply.move,
              probability: switch (reply.move.san) {
                'Qf6' => 0.45,
                'Qd6' => 0.3,
                _ => reply.probability,
              },
              child: reply.child,
            ),
        ],
      );
      final rows = searchRows(side: Side.white, mine: often);
      expect([for (final r in rows) r.move.san], ['Qf6', 'Qd6', 'Qb4']);
      expect([for (final r in rows) r.trapLossCp], [null, 110, null]);
    });

    test('one search alone still fills its side', () {
      final rows = searchRows(side: Side.black, mine: forBlack);
      expect(rows, hasLength(3));
      expect(rows.every((r) => r.white == null && r.share == null), isTrue);
      expect(searchRows(side: Side.white), isEmpty);
      expect(
        searchRows(side: Side.white, mine: _worth('leaf', 0)),
        isEmpty,
        reason: 'a leaf has no moves',
      );
    });
  });

  group('who gave a share', () {
    OpponentNode replies(RepliesFrom? from) => OpponentNode.over(
      fen: _board,
      evalForUs: const Eval(0),
      repliesFrom: from,
      replies: forWhite.replies,
    );
    String tip(RepliesFrom from) => repliesFromTip(
      from,
      database: 'Lichess masters',
      elo: 2200,
      fallbackUnder: 10,
    );

    test('each row carries the source of the search that gave its share', () {
      final rows = searchRows(
        side: Side.black,
        mine: forBlack,
        other: replies(RepliesFrom.maia),
      );
      expect(
        [for (final r in rows) r.shareFrom],
        [RepliesFrom.maia, RepliesFrom.maia, null, RepliesFrom.maia],
        reason: 'Qc5 has no share, so no source',
      );
      expect(
        searchRows(side: Side.white, mine: forWhite).map((r) => r.shareFrom),
        everyElement(isNull),
        reason: 'Maia alone, or a tree saved before sources were kept',
      );
      expect(tip(RepliesFrom.games), 'From Lichess masters');
      expect(
        tip(RepliesFrom.maia),
        'Maia 2200; Lichess masters has under 10 games here',
      );
    });

    Future<void> pumpFrom(WidgetTester tester, RepliesFrom? from) =>
        tester.pumpWidget(
          MaterialApp(
            theme: darkTheme(),
            home: Scaffold(
              body: SizedBox(
                width: 480,
                height: 300,
                child: SearchTable(
                  rows: searchRows(side: Side.white, mine: replies(from)),
                  ours: false,
                  sides: const [Side.white, Side.black],
                  engineDepthAt: (_) => null,
                  shareTip: tip,
                  onHover: (_, _) {},
                  onLeave: () {},
                  onPlay: (_) {},
                ),
              ),
            ),
          ),
        );

    testWidgets('Maia standing in is marked ~ and named on the share', (
      tester,
    ) async {
      await pumpFrom(tester, RepliesFrom.maia);
      expect(find.text('~60%'), findsOneWidget);
      expect(find.text('60%'), findsNothing);
      expect(
        find.byTooltip('Maia 2200; Lichess masters has under 10 games here'),
        findsNWidgets(3),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the database\'s own shares are unmarked, named on hover', (
      tester,
    ) async {
      await pumpFrom(tester, RepliesFrom.games);
      expect(find.text('60%'), findsOneWidget);
      expect(find.byTooltip('From Lichess masters'), findsNWidgets(3));
    });

    testWidgets('an unknown source shows nothing extra', (tester) async {
      await pumpFrom(tester, null);
      expect(find.text('60%'), findsOneWidget);
      expect(find.textContaining('~'), findsNothing);
      expect(find.byTooltip('From Lichess masters'), findsNothing);
    });
  });

  group('SearchTable', () {
    Future<void> pump(
      WidgetTester tester, {
      required double width,
      List<Side> sides = const [Side.white, Side.black],
      ValueChanged<SearchRow>? onPlay,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: 300,
              child: SearchTable(
                rows: searchRows(
                  side: Side.black,
                  mine: forBlack,
                  other: forWhite,
                ),
                ours: true,
                sides: sides,
                engineDepthAt: (after) =>
                    after.value == 'after Qb4' ? 18 : null,
                onHover: (_, _) {},
                onLeave: () {},
                onPlay: onPlay ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('a column for each side beside the engine, and the share', (
      tester,
    ) async {
      SearchRow? played;
      await pump(tester, width: 480, onPlay: (row) => played = row);
      for (final name in ['Your move', 'Played', 'White', 'Black', 'Engine']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(
        find.byTooltip(
          'White plays its best moves; Black replies the way players do. '
          'Scored from White\'s side.',
        ),
        findsOneWidget,
      );
      expect(find.text('25%'), findsOneWidget);
      // Qb4: White's search has White a pawn and a half up, Black's has
      // Black slightly better, and the engine agrees with Black's.
      expect(find.text('+1.50'), findsOneWidget);
      expect(find.text('-0.20'), findsNWidgets(2));
      // Qf6 is worth the same to both searches and to the engine.
      expect(find.text('+0.10'), findsNWidgets(3));
      expect(find.text('…'), findsOneWidget, reason: 'Qc5 is not searched');
      expect(find.byTooltip('Depth 18'), findsOneWidget);
      await tester.tap(find.text('Qb4'));
      expect(played?.move.san, 'Qb4');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a narrow pane leaves out Played and keeps the values', (
      tester,
    ) async {
      await pump(tester, width: 240);
      expect(find.text('Played'), findsNothing);
      expect(find.text('25%'), findsNothing);
      expect(find.text('White'), findsOneWidget);
      expect(find.text('Black'), findsOneWidget);
      expect(find.text('Engine'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the mainline book has one value column', (tester) async {
      await pump(tester, width: 480, sides: const [Side.black]);
      expect(find.text('Value'), findsOneWidget);
      expect(find.text('White'), findsNothing);
      expect(find.text('Black'), findsNothing);
    });
  });
}
