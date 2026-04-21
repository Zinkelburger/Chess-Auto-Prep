import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/generation/tree_serialization.dart';

import 'eval_tree_test_helpers.dart';

void main() {
  test('tree serialization preserves viewer-facing eval tree fields', () {
    final tree = makeEvalTreeTestTree();
    tree.startMoves = 'd4 d5';
    final e4 = tree.root.children.first;
    final json = serializeTree(tree);
    final restored = deserializeTree(json);
    final restoredE4 = restored.root.children.first;

    expect(json, contains('"version": 4'));
    expect(json, contains('"start_moves": "d4 d5"'));
    expect(restored.startMoves, 'd4 d5');
    expect(restoredE4.moveSan, e4.moveSan);
    expect(restoredE4.isRepertoireMove, isTrue);
    expect(restoredE4.repertoireScore, closeTo(e4.expectimaxValue, 0.001));
    expect(restoredE4.subtreeDepth, e4.subtreeDepth);
    expect(restoredE4.trapScore, closeTo(e4.trapScore, 0.001));
  });

  test(
      'deserializeTree treats missing build_complete as a completed legacy tree',
      () {
    final restored = deserializeTree('''
{
  "format": "opening_tree",
  "version": 3,
  "tree": {
    "id": 1,
    "depth": 0,
    "fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "is_white_to_move": true
  }
}
''');

    expect(restored.buildComplete, isTrue);
  });
}
