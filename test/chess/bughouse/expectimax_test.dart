import 'package:chess_auto_prep/chess/bughouse/expectimax.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Map<String, double>> uniform(TablePosition p, BoardNumber b) async {
  final legal = p.legalMoves(b);
  return {for (final m in legal) m.uci: 1 / legal.length};
}

void main() {
  test(
    'weights human mistakes, preserves the tail, considers every own move',
    () async {
      Future<Map<String, double>> policy(TablePosition p, BoardNumber b) async {
        if (p.turn(b) == Side.white) return uniform(p, b);
        return {
          for (final m in p.legalMoves(b))
            m.uci: switch (m.uci) {
              'd7d5' => .9,
              'e7e5' => .1,
              _ => 0,
            },
        };
      }

      Future<double> evaluate(TablePosition p) async {
        if (p.one.board.pieceAt(Square.e4)?.role != Role.pawn) return .1;
        if (p.one.board.pieceAt(Square.d5) != null) return .8;
        if (p.one.board.pieceAt(Square.e5) != null) return -.8;
        return -.2;
      }

      Future<BughouseBranch> e4(double coverage) async {
        final search = BughouseExpectimax(
          board: BoardNumber.one,
          team: Team.ab,
          policy: policy,
          evaluate: evaluate,
          options: BughouseSearchOptions(replyCoverage: coverage),
          cancelled: () => false,
        );
        final rows = await search.search(TablePosition.initial).toList();
        expect(rows.length, 20);
        rows.sort((a, b) => b.child.expected.compareTo(a.child.expected));
        expect(rows.first.move.uci, 'e2e4');
        return rows.first;
      }

      final all = await e4(1);
      expect(all.child.evaluation, -.2);
      expect(all.child.expected, closeTo(.64, 1e-9));
      final cut = await e4(.9);
      expect(cut.child.coverage, closeTo(.9, 1e-9));
      expect(cut.child.expected, closeTo(.9 * .8 + .1 * -.2, 1e-9));
      expect(cut.child.branches.length, 1);
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
        team: Team.cd,
        policy: uniform,
        evaluate: (position) async {
          if (position.two.board.pieceAt(Square.d5)?.color == Side.white)
            captured = position;
          return -.4;
        },
        options: const BughouseSearchOptions(plies: 1),
        cancelled: () => false,
      );
      final rows = await search.search(p).toList();
      expect(rows.every((r) => r.child.expected == .4), isTrue);
      expect(captured!.one.pockets!.of(Side.black, Role.pawn), 1);
      expect(captured!.two.pockets!.of(Side.white, Role.pawn), 0);
    },
  );

  test('own turns maximize at deeper plies, not average', () async {
    final search = BughouseExpectimax(
      board: BoardNumber.one,
      team: Team.ab,
      policy: uniform,
      evaluate: (p) async =>
          p.one.board.pieceAt(Square.f3)?.role == Role.knight ? .8 : -.2,
      options: const BughouseSearchOptions(
        plies: 3,
        maxReplies: 1,
        replyCoverage: .01,
      ),
      cancelled: () => false,
    );
    final rows = await search.search(TablePosition.initial).toList();
    final e4 = rows.firstWhere((r) => r.move.uci == 'e2e4');
    expect(e4.child.branches.single.child.expected, .8);
    expect(e4.child.branches.single.child.branches.length, greaterThan(1));
  });

  test('terminal mate is decisive without calling a network', () async {
    const fen = '6k1/5ppp/8/8/8/8/5PPP/6K1[Q] w - - 0 1';
    final p = TablePosition(
      Crazyhouse.fromSetup(Setup.parseFen(fen)),
      Crazyhouse.initial,
    );
    final search = BughouseExpectimax(
      board: BoardNumber.one,
      team: Team.ab,
      policy: uniform,
      evaluate: (_) async => 0,
      options: const BughouseSearchOptions(plies: 1),
      cancelled: () => false,
    );
    final rows = await search.search(p).toList();
    expect(rows.firstWhere((r) => r.move.uci == 'Q@e8').child.expected, 1);
  });

  test(
    'cancel, budget exhaustion and invalid distributions never fabricate rows',
    () async {
      var stopped = true;
      BughouseExpectimax search(BughousePolicy policy, int limit) =>
          BughouseExpectimax(
            board: BoardNumber.one,
            team: Team.ab,
            policy: policy,
            evaluate: (_) async => 0,
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
