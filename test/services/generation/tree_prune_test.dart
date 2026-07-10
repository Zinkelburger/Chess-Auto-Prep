// WS-A / B6: characterization tests for the pure tree-shaping helpers in
// `tree_prune.dart`. These lock in the current behavior of eval-too-low
// pruning and cumulative-probability propagation by constructing
// BuildTree/BuildTreeNode structures directly (no engine/network/service).

import 'package:chess_auto_prep/services/generation/frontier_queue.dart';

import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/tree_prune.dart';
import 'package:flutter_test/flutter_test.dart';

int _idCounter = 0;

BuildTreeNode _node({
  String san = 'e4',
  double cumP = 1.0,
  bool explored = false,
  PruneReason prune = PruneReason.none,
}) {
  final n = BuildTreeNode(
    fen: 'fen-$_idCounter',
    moveSan: san,
    moveUci: 'm$_idCounter',
    ply: 0,
    isWhiteToMove: true,
    nodeId: _idCounter++,
    cumulativeProbability: cumP,
  );
  n.explored = explored;
  n.pruneReason = prune;
  return n;
}

/// Build a [BuildTree] from a constructed root and register every node so
/// `nodeIndex` mirrors what the live builder maintains.
BuildTree _treeFrom(BuildTreeNode root) {
  final tree = BuildTree(root: root);
  void register(BuildTreeNode n) {
    tree.registerNode(n);
    for (final c in n.children) {
      register(c);
    }
  }

  register(root);
  tree.totalNodes = root.countSubtree();
  return tree;
}

void main() {
  setUp(() => _idCounter = 0);

  group('pruneEvalTooLow', () {
    test('returns 0 and leaves the tree untouched when nothing is flagged', () {
      final root = _node(san: '');
      root.children.add(_node());
      root.children.add(_node());
      final tree = _treeFrom(root);

      expect(pruneEvalTooLow(tree), 0);
      expect(root.children.length, 2);
      expect(tree.totalNodes, 3);
      expect(tree.nodeIndex.length, 3);
    });

    test('removes a flagged child and its entire subtree', () {
      final root = _node(san: '');
      final keep = _node(san: 'keep');
      final drop = _node(san: 'drop', prune: PruneReason.evalTooLow);
      drop.children.add(_node(san: 'grandchild'));
      drop.children.add(_node(san: 'grandchild2'));
      root.children.addAll([keep, drop]);
      final tree = _treeFrom(root);
      final dropId = drop.nodeId;
      final grandIds = drop.children.map((c) => c.nodeId).toList();

      // 1 root + keep + drop + 2 grandchildren = 5
      expect(tree.totalNodes, 5);

      // drop subtree = drop + 2 grandchildren = 3 nodes removed
      expect(pruneEvalTooLow(tree), 3);
      expect(root.children, [keep]);
      expect(tree.totalNodes, 2);
      // removed nodes are gone from the index; survivors remain
      expect(tree.nodeIndex.containsKey(dropId), isFalse);
      for (final id in grandIds) {
        expect(tree.nodeIndex.containsKey(id), isFalse);
      }
      expect(tree.nodeIndex.containsKey(keep.nodeId), isTrue);
      expect(tree.nodeIndex.containsKey(root.nodeId), isTrue);
    });

    test('prunes flagged nodes nested deep in the tree', () {
      final root = _node(san: '');
      final mid = _node(san: 'mid');
      final flagged = _node(san: 'flagged', prune: PruneReason.evalTooLow);
      flagged.children.add(_node(san: 'leaf'));
      mid.children.add(flagged);
      mid.children.add(_node(san: 'sibling'));
      root.children.add(mid);
      final tree = _treeFrom(root);

      // flagged + its leaf = 2 removed
      expect(pruneEvalTooLow(tree), 2);
      expect(mid.children.map((c) => c.moveSan), ['sibling']);
      expect(tree.totalNodes, root.countSubtree());
    });

    test('records removed subtree roots into removedLines', () {
      final root = _node(san: '');
      final keep = _node(san: 'keep');
      final drop = _node(san: 'drop', cumP: 0.25, prune: PruneReason.evalTooLow);
      drop.engineEvalCp = -180;
      drop.pruneEvalCp = -180;
      drop.children.add(_node(san: 'grandchild'));
      root.children.addAll([keep, drop]);
      final tree = _treeFrom(root);

      final removed = <PrunedLine>[];
      expect(pruneEvalTooLow(tree, removedLines: removed), 2);

      // Only the subtree root is recorded, not its descendants.
      expect(removed.length, 1);
      final line = removed.single;
      expect(line.nodeId, drop.nodeId);
      expect(line.lineSan, 'drop');
      expect(line.pruneEvalCp, -180);
      expect(line.cumulativeProbability, 0.25);
      expect(line.subtreeNodes, 2);
      expect(line.toJson()['line_san'], 'drop');
    });

    test('evalTooHigh and other reasons are NOT pruned', () {
      final root = _node(san: '');
      root.children.add(_node(san: 'high', prune: PruneReason.evalTooHigh));
      final tree = _treeFrom(root);

      expect(pruneEvalTooLow(tree), 0);
      expect(root.children.length, 1);
    });
  });

  group('propagateHigherCumP', () {
    test('is a no-op when newCumP is not greater than current', () {
      final canonical = _node(cumP: 0.5);
      final child = _node(cumP: 0.25);
      canonical.children.add(child);
      final queue = FrontierQueue(bestFirst: false);

      propagateHigherCumP(canonical, 0.5, 0.01, queue);
      expect(canonical.cumulativeProbability, 0.5);
      expect(child.cumulativeProbability, 0.25);
      expect(queue.isEmpty, isTrue);

      propagateHigherCumP(canonical, 0.3, 0.01, queue);
      expect(canonical.cumulativeProbability, 0.5);
      expect(child.cumulativeProbability, 0.25);
      expect(queue.isEmpty, isTrue);
    });

    test('scales node and descendants by the same ratio', () {
      final canonical = _node(cumP: 0.2);
      final child = _node(cumP: 0.1);
      final grandchild = _node(cumP: 0.05);
      child.children.add(grandchild);
      canonical.children.add(child);
      final queue = FrontierQueue(bestFirst: false);

      // newCumP 0.4 over 0.2 → ratio 2.0
      propagateHigherCumP(canonical, 0.4, 0.01, queue);
      expect(canonical.cumulativeProbability, closeTo(0.4, 1e-12));
      expect(child.cumulativeProbability, closeTo(0.2, 1e-12));
      expect(grandchild.cumulativeProbability, closeTo(0.1, 1e-12));
    });

    test('queues unexplored leaves that clear minProbability after scaling',
        () {
      final canonical = _node(cumP: 0.1);
      final leafBig = _node(san: 'big', cumP: 0.06);
      final leafSmall = _node(san: 'small', cumP: 0.005);
      canonical.children.addAll([leafBig, leafSmall]);
      final queue = FrontierQueue(bestFirst: false);

      // ratio 2.0 → leafBig 0.12 (>= 0.01), leafSmall 0.01 (>= 0.01)
      propagateHigherCumP(canonical, 0.2, 0.01, queue);
      expect(queue.contains(leafBig), isTrue);
      expect(queue.contains(leafSmall), isTrue);
    });

    test('does not queue explored leaves or leaves below minProbability', () {
      final canonical = _node(cumP: 0.1);
      final explored = _node(san: 'explored', cumP: 0.06, explored: true);
      final tooSmall = _node(san: 'tiny', cumP: 0.001);
      canonical.children.addAll([explored, tooSmall]);
      final queue = FrontierQueue(bestFirst: false);

      // ratio 2.0 → explored 0.12 (but explored), tooSmall 0.002 (< 0.01)
      propagateHigherCumP(canonical, 0.2, 0.01, queue);
      expect(queue.isEmpty, isTrue);
    });

    test('internal nodes are scaled but never queued', () {
      final canonical = _node(cumP: 0.1);
      final internal = _node(san: 'internal', cumP: 0.08);
      internal.children.add(_node(san: 'leaf', cumP: 0.04));
      canonical.children.add(internal);
      final queue = FrontierQueue(bestFirst: false);

      propagateHigherCumP(canonical, 0.2, 0.01, queue);
      expect(internal.cumulativeProbability, closeTo(0.16, 1e-12));
      expect(queue.contains(internal), isFalse);
      // its leaf (0.08 after scaling) is queued
      expect(queue.length, 1);
      expect(queue.first.moveSan, 'leaf');
    });
  });
}
