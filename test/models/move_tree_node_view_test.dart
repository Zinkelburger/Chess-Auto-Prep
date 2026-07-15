// WS-B1: prove the MoveTreeNodeView interface genuinely unifies the
// structurally-identical move-tree node types, so one generic routine works
// across all of them (the foundation for a single cursor/serializer).

import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/models/move_tree_node_view.dart';
import 'package:flutter_test/flutter_test.dart';

/// A single generic traversal that works over ANY MoveTreeNodeView.
List<String> mainlineSan(MoveTreeNodeView node) {
  final out = <String>[];
  MoveTreeNodeView? cur = node;
  while (cur != null) {
    out.add(cur.san);
    cur = cur.orderedChildren.isEmpty ? null : cur.orderedChildren.first;
  }
  return out;
}

void main() {
  group('MoveTreeNodeView unifies node types', () {
    test('MoveNode implements the interface', () {
      final n = MoveNode(
        san: 'e4',
        fen: 'after-e4',
        children: [MoveNode(san: 'e5', fen: 'after-e5')],
      );
      expect(n, isA<MoveTreeNodeView>());
      expect(n.fenAfter, 'after-e4');
      expect(mainlineSan(n), ['e4', 'e5']);
    });

    test('MoveNode.addChild builds a navigable mainline', () {
      final root = MoveNode(san: 'd4', fen: 'after-d4');
      root.addChild('d5', 'after-d5');
      expect(root, isA<MoveTreeNodeView>());
      expect(mainlineSan(root), ['d4', 'd5']);
    });

    test('BuildTreeNode implements the interface', () {
      final root = BuildTreeNode(
        fen: 'after-c4',
        moveSan: 'c4',
        moveUci: 'c2c4',
        ply: 1,
        isWhiteToMove: false,
        nodeId: 1,
      );
      final child = BuildTreeNode(
        fen: 'after-c5',
        moveSan: 'c5',
        moveUci: 'c7c5',
        ply: 2,
        isWhiteToMove: true,
        nodeId: 2,
        parent: root,
      );
      root.children.add(child);

      expect(root, isA<MoveTreeNodeView>());
      expect(root.san, 'c4');
      expect(root.fenAfter, 'after-c4');
      expect(mainlineSan(root), ['c4', 'c5']);
    });

    test('the same generic routine handles a heterogeneous list', () {
      final nodes = <MoveTreeNodeView>[
        MoveNode(san: 'e4', fen: 'x'),
        MoveNode(san: 'd4', fen: 'y'),
        BuildTreeNode(
          fen: 'z',
          moveSan: 'c4',
          moveUci: 'c2c4',
          ply: 1,
          isWhiteToMove: false,
          nodeId: 1,
        ),
      ];
      expect(nodes.map((n) => mainlineSan(n).first), ['e4', 'd4', 'c4']);
    });
  });
}
