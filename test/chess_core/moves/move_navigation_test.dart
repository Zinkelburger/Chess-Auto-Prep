// MoveNavigation's shared helpers: resolving a SAN line to a tree path.

import 'package:chess_auto_prep/chess_core/moves/move_navigation.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pathForSans', () {
    late MoveTree tree;
    setUp(() {
      tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      // A sideline after 1.e4: 1...c5.
      tree.addMove(const TreePath([0]), 'c5');
    });

    test('follows the sibling that matches each move', () {
      expect(tree.pathForSans(['e4', 'e5', 'Nf3']), const TreePath([0, 0, 0]));
      expect(tree.pathForSans(['e4', 'c5']), const TreePath([0, 1]));
    });

    test('stops at the first move the tree does not have', () {
      expect(tree.pathForSans(['e4', 'e6', 'd4']), const TreePath([0]));
      expect(tree.pathForSans(['d4']), TreePath.empty);
      expect(tree.pathForSans(const []), TreePath.empty);
    });

    test('is stable when siblings are reordered', () {
      tree.promoteVariation(const TreePath([0, 1]));
      expect(tree.pathForSans(['e4', 'c5']), const TreePath([0, 0]));
      expect(tree.pathForSans(['e4', 'e5', 'Nf3']), const TreePath([0, 1, 0]));
    });
  });
}
