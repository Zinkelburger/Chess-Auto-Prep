import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/chess_core/moves/sideline_tree.dart';
import 'package:chess_auto_prep/models/move_tree.dart';

MoveNode _node(String san, {bool ephemeral = false, List<MoveNode>? kids}) =>
    MoveNode(san: san, fen: '', isEphemeral: ephemeral, children: kids);

void main() {
  group('MoveNodeSubtree', () {
    test('pathTo returns the root-first path, matched by id', () {
      final leaf = _node('d4');
      final mid = _node('Nf3', kids: [leaf]);
      final root = _node('c4', kids: [_node('e3'), mid]);

      expect(root.pathTo(leaf), [root, mid, leaf]);
      expect(root.pathTo(root), [root]);
      expect(root.pathTo(_node('d4')), isNull);
    });

    test('findById searches the node itself and every descendant', () {
      final leaf = _node('d4');
      final root = _node(
        'c4',
        kids: [
          _node('e3', kids: [leaf]),
        ],
      );

      expect(root.findById(root.id), same(root));
      expect(root.findById(leaf.id), same(leaf));
      expect(root.findById(-1), isNull);
    });

    test('subtreeHasEphemeral sees a scratch move at any depth', () {
      final saved = _node('c4', kids: [_node('e3')]);
      expect(saved.subtreeHasEphemeral, isFalse);
      saved.children.first.children.add(_node('d4', ephemeral: true));
      expect(saved.subtreeHasEphemeral, isTrue);
    });

    test('removeEphemeralDescendants keeps the node and saved children', () {
      final root = _node(
        'c4',
        ephemeral: true,
        kids: [
          _node('e3', kids: [_node('d4', ephemeral: true)]),
          _node('Nf3', ephemeral: true),
        ],
      );
      root.removeEphemeralDescendants();
      expect(root.isEphemeral, isTrue);
      expect(root.children.map((c) => c.san), ['e3']);
      expect(root.children.single.children, isEmpty);
    });

    test('removeDescendant detaches a nested child with its subtree', () {
      final target = _node('d4', kids: [_node('Nf6')]);
      final root = _node(
        'c4',
        kids: [
          _node('e3', kids: [target]),
        ],
      );

      expect(root.removeDescendant(target.id), isTrue);
      expect(root.children.single.children, isEmpty);
      expect(root.removeDescendant(target.id), isFalse);
    });
  });

  group('SidelineForest', () {
    late MoveNode deep;
    late MoveNode rootAt2;
    late SidelineForest forest;

    setUp(() {
      deep = _node('Nc6');
      rootAt2 = _node('Nf3', kids: [deep]);
      forest = {
        0: [_node('d4', ephemeral: true)],
        2: [_node('Bc4'), rootAt2],
      };
    });

    test('pathToNode finds a node under any ply, or only the given one', () {
      expect(forest.pathToNode(deep), [rootAt2, deep]);
      expect(forest.pathToNode(deep, branchPly: 2), [rootAt2, deep]);
      expect(forest.pathToNode(deep, branchPly: 0), isNull);
      expect(forest.pathToNode(deep, branchPly: 7), isNull);
    });

    test('findNodeById and hasEphemeral span every ply', () {
      expect(forest.findNodeById(deep.id), same(deep));
      expect(forest.findNodeById(-1), isNull);
      expect(forest.hasEphemeral, isTrue);
      forest.remove(0);
      expect(forest.hasEphemeral, isFalse);
    });

    test('removeEphemeral drops scratch nodes and empty plies', () {
      rootAt2.children.add(_node('e5', ephemeral: true));
      forest.removeEphemeral();

      expect(forest.keys, [2]);
      expect(forest[2]!.map((r) => r.san), ['Bc4', 'Nf3']);
      expect(rootAt2.children.map((c) => c.san), ['Nc6']);
    });

    test('removeNode reports whether the node was a root', () {
      expect(forest.removeNode(deep.id), (branchPly: 2, wasRoot: false));
      expect(rootAt2.children, isEmpty);
      expect(forest.removeNode(rootAt2.id), (branchPly: 2, wasRoot: true));
      expect(forest[2]!.map((r) => r.san), ['Bc4']);
      expect(forest.removeNode(rootAt2.id), isNull);
    });
  });
}
