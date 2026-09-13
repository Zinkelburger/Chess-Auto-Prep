import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/generate/services/position_moves.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'live child evaluation updates without rebuilding the saved database',
    () {
      final node = BuildTreeNode(
        fen: playUciMove(kStandardStartFen, 'e2e4')!,
        moveSan: 'e4',
        moveUci: 'e2e4',
        ply: 1,
        isWhiteToMove: false,
        nodeId: 1,
      )..engineEvalCp = -25;
      BuildTreeNode? lookup(String fen) =>
          canonicalizeFen(fen) == canonicalizeFen(node.fen) ? node : null;
      expect(
        positionMoves(kStandardStartFen, liveNodeAt: lookup).first.evalCp,
        25,
      );
      node.engineEvalCp = -42;
      expect(
        positionMoves(kStandardStartFen, liveNodeAt: lookup).first.evalCp,
        42,
      );
    },
  );

  test('lists all legal moves even without analysis', () {
    final rows = positionMoves(kStandardStartFen);
    expect(rows.length, 20);
    expect(rows.every((r) => r.evalCp == null && r.expectedCp == null), isTrue);
    expect(rows.map((r) => r.san), containsAll(['e4', 'd4', 'Nf3']));
  });
  test('finds standalone child probes and converts scores to White', () {
    final fen = playUciMove(kStandardStartFen, 'e2e4')!;
    final node =
        BuildTreeNode(
            fen: fen,
            moveSan: '',
            moveUci: '',
            ply: 0,
            isWhiteToMove: false,
            nodeId: 1,
          )
          ..engineEvalCp = -35
          ..expectimaxValue = 0.7
          ..hasExpectimax = true;
    final map = FenMap()..populate(node);
    final rows = positionMoves(kStandardStartFen, database: map);
    expect(rows.first.san, 'e4');
    expect(rows.first.evalCp, 35);
    expect(rows.first.expectedCp, greaterThan(0));
    expect(rows.where((r) => r.expectedCp == null).length, 19);
    expect(
      positionMoves(
        kStandardStartFen,
        database: map,
        playAsWhite: false,
      ).firstWhere((r) => r.san == 'e4').expectedCp,
      lessThan(0),
    );
  });
  test('includes underpromotions and standard castling UCI', () {
    final promotions = positionMoves('7k/P7/8/8/8/8/8/7K w - - 0 1');
    expect(promotions.where((r) => r.uci.startsWith('a7a8')).length, 4);
    final castles = positionMoves('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1');
    expect(castles.firstWhere((r) => r.san == 'O-O').uci, 'e1g1');
  });
  test('terminal positions have no moves', () {
    expect(positionMoves('7k/6Q1/5K2/8/8/8/8/8 b - - 0 1'), isEmpty);
  });
}
