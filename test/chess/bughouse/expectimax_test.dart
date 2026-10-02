import 'package:chess_auto_prep/chess/bughouse/expectimax.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Map<String, double>> uniform(TablePosition p, BoardNumber b) async {
  final legal = p.legalMoves(b);
  return {for (final m in legal) m.uci: 1 / legal.length};
}

void main() {
  test('weights human mistakes and preserves unexpanded tail mass', () async {
    Future<Map<String, double>> policy(TablePosition p, BoardNumber b) async {
      if (p.turn(b) == Side.white) return uniform(p, b);
      return {
        for (final m in p.legalMoves(b))
          m.uci: switch (m.uci) {
            'd7d5' => .9,
            'e7e5' => .09,
            'c7c5' => .01,
            _ => 0,
          },
      };
    }

    double raw(TablePosition p) {
      if (p.one.board.pieceAt(Square.e4)?.role != Role.pawn) return .1;
      if (p.one.board.pieceAt(Square.d5) != null) return .8;
      if (p.one.board.pieceAt(Square.e5) != null) return -.8;
      return -.2;
    }

    Future<BughouseEvaluation> evaluate(TablePosition p, BoardNumber b) async =>
        (
          value: raw(p),
          best: p.play(b, 'e2e4') != null ? 'e2e4' : p.legalMoves(b).first.uci,
          nodes: 1500,
          depth: 8,
        );
    final search = BughouseExpectimax(
      board: BoardNumber.one,
      policy: policy,
      evaluate: evaluate,
      options: const BughouseSearchOptions(),
      cancelled: () => false,
    );
    final rows = await search.search(TablePosition.initial).toList();
    expect(rows.length, lessThanOrEqualTo(5));
    final row = rows.firstWhere((r) => r.move.uci == 'e2e4');
    expect(row.child.evaluation, -.2);
    expect(row.child.white, closeTo(.646, 1e-9));
    expect(row.child.black, -.8);
    expect(row.child.coverage, closeTo(.99, 1e-9));
  });

  test(
    'Black root shares evaluations while White maximizes and Black averages',
    () async {
      var calls = 0;
      final root = TablePosition.initial.play(BoardNumber.one, 'e2e4')!.after;
      final search = BughouseExpectimax(
        board: BoardNumber.one,
        policy: (p, b) async => {
          for (final m in p.legalMoves(b))
            m.uci: p.turn(b) == Side.black
                ? (m.uci == 'd7d5' ? 1.0 : 0.0)
                : (m.uci == 'g1f3'
                      ? .75
                      : m.uci == 'b1c3'
                      ? .25
                      : 0.0),
        },
        evaluate: (p, b) async {
          calls++;
          return (
            value: p.one.board.pieceAt(Square.f3)?.role == Role.knight
                ? .8
                : p.one.board.pieceAt(Square.c3)?.role == Role.knight
                ? -.4
                : 0.0,
            best: p.turn(b) == Side.black ? 'd7d5' : 'g1f3',
            nodes: 1500,
            depth: 8,
          );
        },
        options: const BughouseSearchOptions(),
        cancelled: () => false,
      );
      final rows = await search.search(root).toList();
      expect(rows, hasLength(1));
      expect(rows.single.child.white, .8);
      expect(rows.single.child.black, closeTo(.5, 1e-9));
      expect(
        calls,
        4,
      ); // Root, candidate and two replies, shared by both colours.
    },
  );

  test(
    'board two uses its moving team perspective and preserves capture transfer',
    () async {
      var p = TablePosition.initial;
      for (final move in ['e2e4', 'd7d5']) {
        p = p.play(BoardNumber.two, move)!.after;
      }
      TablePosition? captured;
      final search = BughouseExpectimax(
        board: BoardNumber.two,

        policy: uniform,
        evaluate: (position, b) async {
          if (position.two.board.pieceAt(Square.d5)?.color == Side.white)
            captured = position;
          return (
            value: -.4,
            best:
                position.play(b, 'e4d5')?.move.uci ??
                position.legalMoves(b).first.uci,
            nodes: 1500,
            depth: 8,
          );
        },
        options: const BughouseSearchOptions(plies: 1),
        cancelled: () => false,
      );
      final rows = await search.search(p).toList();
      expect(rows.every((r) => r.child.white == .4), isTrue);
      expect(captured!.one.pockets!.of(Side.black, Role.pawn), 1);
      expect(captured!.two.pockets!.of(Side.white, Role.pawn), 0);
    },
  );

  test(
    'candidate beam retains engine choice below 1%, excludes other rare moves',
    () {
      final p = TablePosition.initial;
      final legal = p.legalMoves(BoardNumber.one);
      final probabilities = {for (final m in legal) m.uci: .001};
      for (final (i, m) in legal.take(5).indexed) {
        probabilities[m.uci] = .3 - i * .04;
      }
      probabilities['e2e4'] = .001;
      final moves = bughouseCandidates(
        p,
        BoardNumber.one,
        probabilities,
        'e2e4',
      );
      expect(moves.length, 5);
      expect(moves.map((m) => m.uci), contains('e2e4'));
      expect(moves.map((m) => m.uci), isNot(contains(legal[4].uci)));
      probabilities[legal[0].uci] = .01;
      expect(
        bughouseCandidates(
          p,
          BoardNumber.one,
          probabilities,
          'e2e4',
        ).map((m) => m.uci),
        isNot(contains(legal[0].uci)),
      );
    },
  );

  test('terminal mate is decisive without calling a network', () async {
    const fen = '6k1/5ppp/8/8/8/8/5PPP/6K1[Q] w - - 0 1';
    final p = TablePosition(
      Crazyhouse.fromSetup(Setup.parseFen(fen)),
      Crazyhouse.initial,
    );
    final search = BughouseExpectimax(
      board: BoardNumber.one,

      policy: uniform,
      evaluate: (p, b) async => (
        value: 0.0,
        best: p.play(b, 'Q@e8')?.move.uci ?? p.legalMoves(b).first.uci,
        nodes: 1500,
        depth: 8,
      ),
      options: const BughouseSearchOptions(plies: 1),
      cancelled: () => false,
    );
    final rows = await search.search(p).toList();
    expect(rows.firstWhere((r) => r.move.uci == 'Q@e8').child.white, 1);
  });

  test(
    'cancel, budget exhaustion and invalid distributions never fabricate rows',
    () async {
      var stopped = true;
      BughouseExpectimax search(BughousePolicy policy, int limit) =>
          BughouseExpectimax(
            board: BoardNumber.one,

            policy: policy,
            evaluate: (p, b) async => (
              value: 0.0,
              best: p.play(b, 'Q@e8')?.move.uci ?? p.legalMoves(b).first.uci,
              nodes: 1500,
              depth: 8,
            ),
            options: BughouseSearchOptions(maxPositions: limit),
            cancelled: () => stopped,
          );
      await expectLater(
        search(uniform, 100).search(TablePosition.initial).toList(),
        throwsA(isA<BughouseSearchStopped>()),
      );
      stopped = false;
      await expectLater(
        search(uniform, 1).search(TablePosition.initial).toList(),
        throwsA(isA<BughouseSearchStopped>()),
      );
      await expectLater(
        search(
          (_, _) async => {'pass': 1},
          100,
        ).search(TablePosition.initial).toList(),
        throwsStateError,
      );
    },
  );
}
