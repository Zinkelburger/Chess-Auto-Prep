import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/build_subtree.dart';

import 'generation_test_helpers.dart';

void main() {
  group('extractRebasedSubtree', () {
    test('rebases plies to zero and renumbers node ids from 1', () {
      final t = StandardTree();
      final tree = extractRebasedSubtree(t.e4, playAsWhite: true);

      expect(tree.root.ply, 0);
      expect(tree.root.fen, t.e4.fen);
      expect(tree.root.moveSan, '', reason: 'root is a position, not a move');
      expect(tree.root.moveUci, '');
      expect(tree.root.nodeId, 1);
      expect(tree.totalNodes, 5);
      expect(tree.nodeIndex.length, 5);

      final e5 = tree.root.children.firstWhere((c) => c.moveSan == 'e5');
      expect(e5.ply, 1);
      expect(e5.parent, same(tree.root));
      final nf3 = e5.children.single;
      expect(nf3.ply, 2);
      expect(nf3.moveSan, 'Nf3');
    });

    test('recomputes cumulative probability from the new root', () {
      final t = StandardTree();
      // Old cumP values are relative to the old root; after extraction the
      // opponent replies to e4 must carry their own local probability and
      // our answers must inherit it unchanged.
      final tree = extractRebasedSubtree(t.e4, playAsWhite: true);

      expect(tree.root.cumulativeProbability, 1.0);
      expect(tree.root.moveProbability, 1.0);
      final e5 = tree.root.children.firstWhere((c) => c.moveSan == 'e5');
      final c5 = tree.root.children.firstWhere((c) => c.moveSan == 'c5');
      expect(e5.cumulativeProbability, closeTo(0.55, 1e-9));
      expect(c5.cumulativeProbability, closeTo(0.35, 1e-9));
      expect(e5.children.single.cumulativeProbability, closeTo(0.55, 1e-9));
    });

    test('preserves evals, explored state, and prune reasons', () {
      final t = StandardTree();
      t.e4e5.explored = true;
      t.e4c5
        ..explored = true
        ..pruneReason = PruneReason.evalTooHigh
        ..pruneEvalCp = 320;
      t.e4e5nf3
        ..expectimaxValue = 0.61
        ..hasExpectimax = true;

      final tree = extractRebasedSubtree(t.e4, playAsWhite: true);
      final e5 = tree.root.children.firstWhere((c) => c.moveSan == 'e5');
      final c5 = tree.root.children.firstWhere((c) => c.moveSan == 'c5');

      expect(e5.engineEvalCp, t.e4e5.engineEvalCp);
      expect(e5.explored, isTrue);
      expect(c5.pruneReason, PruneReason.evalTooHigh);
      expect(c5.pruneEvalCp, 320);
      expect(e5.children.single.expectimaxValue, 0.61);
      expect(e5.children.single.hasExpectimax, isTrue);
    });

    test('resets search priority so resume rederives it', () {
      final t = StandardTree();
      t.e4e5.searchPriority = 0.4;
      final tree = extractRebasedSubtree(t.e4, playAsWhite: true);
      final e5 = tree.root.children.firstWhere((c) => c.moveSan == 'e5');
      expect(e5.searchPriority, -1.0);
    });

    test('does not mutate the source tree', () {
      final t = StandardTree();
      final oldIds = [t.e4.nodeId, t.e4e5.nodeId];
      extractRebasedSubtree(t.e4, playAsWhite: true);
      expect(t.e4.ply, 1);
      expect(t.e4e5.cumulativeProbability, closeTo(0.55, 1e-9));
      expect([t.e4.nodeId, t.e4e5.nodeId], oldIds);
      expect(t.e4.parent, same(t.root));
    });
  });

  group('reopenExpansionLeaves', () {
    test('reopens depth-capped leaves, keeps pruned and deep ones closed', () {
      final t = StandardTree();
      // All ply-3 nodes are childless; mark them explored (depth-capped).
      for (final leaf in [t.e4e5nf3, t.e4c5nf3, t.d4d5c4, t.d4nf6c4]) {
        leaf.explored = true;
      }
      t.e4c5nf3.pruneReason = PruneReason.evalTooHigh;

      final reopened = reopenExpansionLeaves(t.root, belowPly: 5);
      expect(reopened, 3);
      expect(t.e4e5nf3.explored, isFalse);
      expect(t.e4c5nf3.explored, isTrue, reason: 'pruned leaves stay closed');
      expect(t.e4e5.explored, isFalse, reason: 'interior nodes untouched');
    });

    test('leaves at or beyond belowPly stay closed', () {
      final t = StandardTree();
      t.e4e5nf3.explored = true;
      expect(reopenExpansionLeaves(t.root, belowPly: 3), 0);
      expect(t.e4e5nf3.explored, isTrue);
    });

    test('unexplored leaves are not counted', () {
      final t = StandardTree();
      expect(reopenExpansionLeaves(t.root, belowPly: 10), 0);
    });
  });
}
