import 'package:chess_auto_prep/services/generation/skeleton_plan.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

const _benkoL1 = '1.d4 Nf6 2.c4 c5 3.Nf3 cxd4 4.Nxd4 e5';
const _benkoL2 = '1.d4 Nf6 2.c4 c5 3.d5 b5 4.cxb5 a6 5.bxa6 e6';

Position _after(String sans) {
  Position pos = Chess.initial;
  for (final tok in sans.split(RegExp(r'\s+'))) {
    final t = tok.replaceAll(RegExp(r'^\d+\.(\.\.)?'), '');
    if (t.isEmpty) continue;
    pos = pos.play(pos.parseSan(t)!);
  }
  return pos;
}

void main() {
  group('parseLines', () {
    test('records our-move nodes only, for the side we play', () {
      final nodes = SkeletonPlan.parseLines([_benkoL2], playAsWhite: false);
      // Black moves: Nf6, c5, b5, a6, e6 = 5 our-move decisions.
      expect(nodes.map((n) => n.uci).length, 5);
      expect(nodes.first.pathLabel, '1.d4'); // before ...Nf6
      // The c5 node is recorded before ...c5, path "1.d4 Nf6 2.c4".
      final c5 = nodes[1];
      expect(c5.pathLabel, '1.d4 Nf6 2.c4');
    });

    test('stops a line at the first illegal token, keeps the prefix', () {
      final nodes = SkeletonPlan.parseLines([
        '1.d4 Nf6 2.c4 Qh4 3.Nf3',
      ], playAsWhite: false);
      // ...Nf6 is the only legal black move before the illegal Qh4.
      expect(nodes.length, 1);
    });
  });

  group('transferFor', () {
    late SkeletonPlan plan;
    setUp(() {
      plan = SkeletonPlan(
        nodes: SkeletonPlan.parseLines([
          _benkoL1,
          _benkoL2,
        ], playAsWhite: false),
      );
    });

    test('after 1.d4 Nf6 2.Nf3, transfers ...c5 from the 2.c4 line', () {
      final pos = _after('1.d4 Nf6 2.Nf3');
      final m = plan.transferFor(pos.fen);
      expect(m, isNotNull);
      // The nearest skeleton node that played a legal move here is "after 2.c4"
      // which played ...c5 (c7c5).
      expect(m!.uci, 'c7c5');
      expect(m.diff, lessThanOrEqualTo(5));
    });

    test('a caller-supplied position gives the same answer as the FEN', () {
      final pos = _after('1.d4 Nf6 2.Nf3');
      final byFen = plan.transferFor(pos.fen);
      final byPos = plan.transferFor(pos.fen, position: pos);
      expect(byPos?.uci, byFen?.uci);
      expect(byPos?.diff, byFen?.diff);
      expect(byPos?.pathLabel, byFen?.pathLabel);
    });

    test('a skeleton move that is illegal here is never transferred', () {
      // After 1.d4 d5 2.c4 the c-pawn is gone from c7... no: Black's c7 pawn
      // is still there, but after 1.d4 c5 2.d5 the ...c5 push is impossible.
      final pos = _after('1.d4 c5 2.d5');
      final m = plan.transferFor(pos.fen, position: pos);
      expect(m?.uci, isNot('c7c5'));
    });

    test('expandedPlacement is the 64-cell board of the node', () {
      final node = plan.nodes.first; // before ...Nf6, after 1.d4
      expect(node.expandedPlacement, hasLength(64));
      expect(node.expandedPlacement.substring(0, 8), 'rnbqkbnr');
      expect(node.expandedPlacement[35], 'P'); // d4
    });

    test('after 2.Bf4, still transfers ...c5', () {
      final m = plan.transferFor(_after('1.d4 Nf6 2.Bf4').fen);
      expect(m?.uci, 'c7c5');
    });

    test('a far-off position transfers nothing within the cap', () {
      final m = plan.transferFor(_after('1.e4 e5 2.Nf3 Nc6 3.Bb5').fen);
      expect(m, isNull);
    });
  });

  group('structure features', () {
    test('PawnOnSquare(d5, ours) vetoes a position with our pawn on d5', () {
      const f = PawnOnSquare(square: 'd5');
      final withD5 = _after(
        '1.d4 d5',
      ); // black to move? no: white played d4, black d5 -> white to move
      // From Black's perspective (ourSide black), is there a black pawn on d5?
      expect(f.score(withD5, Side.black), -1.0);
      final without = _after('1.d4 Nf6');
      expect(f.score(without, Side.black), 0.0);
    });

    test('EarlyQueenTrade vetoes when our queen is gone', () {
      const f = EarlyQueenTrade();
      final traded = _after('1.d4 d5 2.Nc3 Nf6 3.e4 dxe4 4.d5 Qxd5 5.Nxd5');
      expect(f.score(traded, Side.black), -1.0);
      final normal = _after('1.d4 Nf6');
      expect(f.score(normal, Side.black), 0.0);
    });
  });

  group('json round trip', () {
    test('survives encode/decode', () {
      final plan = SkeletonPlan(
        nodes: SkeletonPlan.parseLines([_benkoL2], playAsWhite: false),
        features: const [
          PawnOnSquare(square: 'd5'),
          EarlyQueenTrade(),
        ],
      );
      final restored = SkeletonPlan.fromJson(plan.toJson());
      expect(restored.nodes.length, plan.nodes.length);
      expect(restored.features.length, 2);
      expect(restored.transferFor(_after('1.d4 Nf6 2.Nf3').fen)?.uci, 'c7c5');
    });
  });
}
