import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:flutter_test/flutter_test.dart';

BuildTreeNode _node(String fen, {int id = 1}) => BuildTreeNode(
  fen: fen,
  moveSan: '',
  moveUci: '',
  ply: 0,
  isWhiteToMove: true,
  nodeId: id,
);

void main() {
  const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  test('freeze rejects mutation but still allows lookup', () {
    final root = _node(start);
    final map = FenMap()..populate(root);
    map.freeze();

    expect(map.isFrozen, isTrue);
    expect(map.getCanonical(start), same(root));
    expect(() => map.clear(), throwsStateError);
    expect(() => map.populate(root), throwsStateError);
    expect(
      () => map.putCanonical(start, _node(start, id: 2)),
      throwsStateError,
    );
  });

  test(
    'isTranspositionCycle only trips when following a transposition leaf',
    () {
      final canonical = _node(start, id: 1);
      final leaf = _node(start, id: 2);
      final visited = <String>{};
      enterFenPath(canonical, visited);

      expect(isTranspositionCycle(canonical, canonical, visited), isFalse);
      expect(isTranspositionCycle(leaf, canonical, visited), isTrue);
      expect(enterPositionOnce(canonical, <String>{}), isTrue);
      expect(enterPositionOnce(canonical, {canonicalizeFen(start)}), isFalse);
    },
  );
}
