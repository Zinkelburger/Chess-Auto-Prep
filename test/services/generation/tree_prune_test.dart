// WS-A / B6: characterization tests for the pure tree-shaping helpers in
// `tree_prune.dart`. These lock in the current behavior of eval-too-low
// pruning and cumulative-probability propagation by constructing
// BuildTree/BuildTreeNode structures directly (no engine/network/service).

import 'package:chess_auto_prep/services/generation/fen_map.dart';
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

      expect(pruneEvalTooLow(tree, playAsWhite: false), 0);
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
      expect(pruneEvalTooLow(tree, playAsWhite: false), 3);
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
      expect(pruneEvalTooLow(tree, playAsWhite: false), 2);
      expect(mid.children.map((c) => c.moveSan), ['sibling']);
      expect(tree.totalNodes, root.countSubtree());
    });

    test('records removed subtree roots into removedLines', () {
      final root = _node(san: '');
      final keep = _node(san: 'keep');
      final drop = _node(
        san: 'drop',
        cumP: 0.25,
        prune: PruneReason.evalTooLow,
      );
      drop.engineEvalCp = -180;
      drop.pruneEvalCp = -180;
      drop.children.add(_node(san: 'grandchild'));
      root.children.addAll([keep, drop]);
      final tree = _treeFrom(root);

      final removed = <PrunedLine>[];
      expect(
        pruneEvalTooLow(tree, playAsWhite: false, removedLines: removed),
        2,
      );

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

    group('never leaves us without a move', () {
      /// Our-turn parent (we are White here) whose every reply is flagged.
      (BuildTree, BuildTreeNode, List<BuildTreeNode>) allFlagged() {
        final root = _node(san: '');
        final ours = _node(san: 'ourTurn');
        final bad = _node(san: 'bad', prune: PruneReason.evalTooLow)
          ..engineEvalCp = -300;
        final lessBad = _node(san: 'lessBad', prune: PruneReason.evalTooLow)
          ..engineEvalCp = -120;
        ours.children.addAll([bad, lessBad]);
        root.children.add(ours);
        return (_treeFrom(root), ours, [bad, lessBad]);
      }

      test('keeps the least bad reply rather than emptying the node', () {
        final (tree, ours, moves) = allFlagged();

        // One of the two goes; the better one stays as a leaf, so the line
        // ends on our move instead of on the opponent's with nothing to play.
        expect(pruneEvalTooLow(tree, playAsWhite: true), 1);
        expect(ours.children, [moves[1]]);
      });

      test('is idempotent — a second pass keeps the same move', () {
        final (tree, ours, moves) = allFlagged();

        pruneEvalTooLow(tree, playAsWhite: true);
        expect(pruneEvalTooLow(tree, playAsWhite: true), 0);
        expect(ours.children, [moves[1]]);
      });

      test('does not apply where the opponent is to move', () {
        // Same shape, but now it is their turn at the parent: these are
        // positions we chose to enter, and dropping them all is correct.
        final (tree, ours, _) = allFlagged();

        expect(pruneEvalTooLow(tree, playAsWhite: false), 2);
        expect(ours.children, isEmpty);
      });

      test('still drops flagged replies when a good one survives', () {
        final root = _node(san: '');
        final ours = _node(san: 'ourTurn');
        final good = _node(san: 'good')..engineEvalCp = 10;
        final bad = _node(san: 'bad', prune: PruneReason.evalTooLow)
          ..engineEvalCp = -300;
        ours.children.addAll([good, bad]);
        root.children.add(ours);
        final tree = _treeFrom(root);

        expect(pruneEvalTooLow(tree, playAsWhite: true), 1);
        expect(ours.children, [good]);
      });
    });

    test('evalTooHigh and other reasons are NOT pruned', () {
      final root = _node(san: '');
      root.children.add(_node(san: 'high', prune: PruneReason.evalTooHigh));
      final tree = _treeFrom(root);

      expect(pruneEvalTooLow(tree, playAsWhite: false), 0);
      expect(root.children.length, 1);
    });
  });

  group('addArrivalCumP', () {
    BuildTreeNode nodeAt(String fen, {double cumP = 0.0, double p = 1.0}) =>
        _node(cumP: cumP)
          ..moveProbability = p
          ..explored = false;

    test(
      'a second way into a position adds its reach — it does not replace',
      () {
        final canonical = _node(cumP: 0.2);
        final child = _node(cumP: 0.1)..moveProbability = 0.5;
        final grandchild = _node(cumP: 0.05)..moveProbability = 0.5;
        child.children.add(grandchild);
        canonical.children.add(child);
        final queue = FrontierQueue(bestFirst: false);

        addArrivalCumP(canonical, 0.3, 0.01, queue);

        expect(canonical.cumulativeProbability, closeTo(0.5, 1e-12));
        expect(child.cumulativeProbability, closeTo(0.25, 1e-12));
        expect(grandchild.cumulativeProbability, closeTo(0.125, 1e-12));
      },
    );

    test('a smaller arrival still counts (the old max rule ignored it)', () {
      final canonical = _node(cumP: 0.5);
      final queue = FrontierQueue(bestFirst: false);
      addArrivalCumP(canonical, 0.1, 0.01, queue);
      expect(canonical.cumulativeProbability, closeTo(0.6, 1e-12));
    });

    test('a descendant\'s own arrivals are not scaled along', () {
      // child already carries 0.1 from its parent edge plus 0.3 from a
      // transposition of its own.  A new 0.2 arriving at the canonical must
      // add 0.2 × 0.5 = 0.1 to it, not multiply the 0.3 as well.
      final canonical = _node(cumP: 0.2);
      final child = _node(cumP: 0.4)..moveProbability = 0.5;
      canonical.children.add(child);
      addArrivalCumP(canonical, 0.2, 0.01, FrontierQueue(bestFirst: false));
      expect(child.cumulativeProbability, closeTo(0.5, 1e-12));
    });

    test(
      'queues unexplored leaves that clear the floor, re-sifting in place',
      () {
        final canonical = _node(cumP: 0.1);
        final leafBig = _node(san: 'big', cumP: 0.06)..moveProbability = 0.6;
        final leafSmall = _node(san: 'small', cumP: 0.004)
          ..moveProbability = 0.04;
        final tiny = _node(san: 'tiny', cumP: 0.0001)..moveProbability = 0.001;
        final explored = _node(san: 'done', cumP: 0.03, explored: true)
          ..moveProbability = 0.3;
        canonical.children.addAll([leafBig, leafSmall, tiny, explored]);
        final queue = FrontierQueue(bestFirst: true);
        queue.add(leafBig); // already waiting

        addArrivalCumP(canonical, 0.2, 0.01, queue);

        expect(leafBig.cumulativeProbability, closeTo(0.18, 1e-12));
        expect(leafSmall.cumulativeProbability, closeTo(0.012, 1e-12));
        expect(queue.length, 2); // big once, small once
        expect(queue.contains(leafBig), isTrue);
        expect(queue.contains(leafSmall), isTrue);
        expect(queue.contains(tiny), isFalse); // 0.0003 < floor
        expect(queue.contains(explored), isFalse);
      },
    );

    test('search priorities follow the reach', () {
      final canonical = _node(cumP: 0.1)..searchPriority = 0.05;
      final alt = _node(cumP: 0.1)
        ..moveProbability = 1.0
        ..searchPriority =
            0.02 // discounted alternative
        ..searchPriorityDiscount = 0.4;
      final fresh = _node(cumP: 0.0)
        ..moveProbability = 0.5
        ..searchPriority = 0.0
        ..searchPriorityDiscount = 1.0;
      canonical.children.addAll([alt, fresh]);

      addArrivalCumP(canonical, 0.1, 0.001, FrontierQueue(bestFirst: true));

      expect(canonical.searchPriority, closeTo(0.1, 1e-12));
      // alt: reach doubled → priority doubled, discount preserved.
      expect(alt.searchPriority, closeTo(0.04, 1e-12));
      // fresh had nothing to scale: rebuilt from the parent's priority.
      expect(fresh.cumulativeProbability, closeTo(0.05, 1e-12));
      expect(fresh.searchPriority, closeTo(0.1 * 0.5, 1e-12));
    });

    test(
      'forwards through a registered transposition leaf into its canonical',
      () {
        // canonical A ─ p=0.5 ─ leaf T (registered against canonical B)
        // B ─ p=0.5 ─ leafB (unexplored)
        final a = nodeAt('A', cumP: 0.2);
        final t = nodeAt('T', cumP: 0.1, p: 0.5)..explored = true;
        a.children.add(t);
        final b = nodeAt('B', cumP: 0.3);
        final leafB = nodeAt('LB', cumP: 0.15, p: 0.5);
        b.children.add(leafB);
        final map = FenMap()
          ..putCanonical(b.fen, b)
          ..putCanonical(a.fen, a);
        // T has B's position.
        final tAsB = BuildTreeNode(
          fen: b.fen,
          moveSan: 'x',
          moveUci: 'x',
          ply: 1,
          isWhiteToMove: true,
          nodeId: 9999,
          moveProbability: 0.5,
          cumulativeProbability: 0.1,
        )..explored = true;
        a.children
          ..clear()
          ..add(tAsB);
        map.addTransposition(tAsB.fen, tAsB);
        final queue = FrontierQueue(bestFirst: false);

        addArrivalCumP(a, 0.2, 0.01, queue, fenMap: map);

        expect(tAsB.cumulativeProbability, closeTo(0.2, 1e-12));
        expect(b.cumulativeProbability, closeTo(0.4, 1e-12)); // +0.1
        expect(leafB.cumulativeProbability, closeTo(0.2, 1e-12)); // +0.05
        expect(queue.contains(leafB), isTrue);
        expect(t.cumulativeProbability, 0.1); // detached, untouched
      },
    );

    test(
      'a resumed build forwards through the transposition leaves it saved',
      () {
        // What a previous session left on disk:
        //   root ─ a ─ tAsB   childless, explored — closed against b
        //        └ b ─ leafB  childless, unexplored — still on the frontier
        final root = _node(cumP: 1.0);
        final a = nodeAt('A', cumP: 0.2, p: 0.2);
        final b = nodeAt('B', cumP: 0.3, p: 0.3);
        root.children
          ..add(a)
          ..add(b);
        final leafB = nodeAt('LB', cumP: 0.15, p: 0.5);
        b.children.add(leafB);
        final tAsB = BuildTreeNode(
          fen: b.fen,
          moveSan: 'x',
          moveUci: 'x',
          ply: 1,
          isWhiteToMove: true,
          nodeId: 9999,
          moveProbability: 0.5,
          cumulativeProbability: 0.1,
        )..explored = true;
        a.children.add(tAsB);

        // A resume seeds the table from the saved tree and nothing else.
        final map = FenMap()..registerExpanded(root);

        expect(map.getCanonical(b.fen), same(b));
        expect(map.getTranspositions(b.fen), [same(tAsB)]);
        // The unexplored frontier leaf must stay out: it contributes its own
        // full reach when the build finally processes it, and registering it
        // here would count that mass twice.
        expect(map.getTranspositions(leafB.fen), isEmpty);

        final queue = FrontierQueue(bestFirst: false);
        addArrivalCumP(a, 0.2, 0.01, queue, fenMap: map);

        // The new mass reaches tAsB and carries on into b's subtree instead
        // of stopping at the stub.
        expect(tAsB.cumulativeProbability, closeTo(0.2, 1e-12));
        expect(b.cumulativeProbability, closeTo(0.4, 1e-12));
        expect(leafB.cumulativeProbability, closeTo(0.2, 1e-12));
        expect(queue.contains(leafB), isTrue);
      },
    );

    test(
      'an unexplored frontier leaf is not forwarded (it adds itself later)',
      () {
        final a = nodeAt('A', cumP: 0.2);
        final b = nodeAt('B', cumP: 0.3);
        final frontier = BuildTreeNode(
          fen: b.fen,
          moveSan: 'x',
          moveUci: 'x',
          ply: 1,
          isWhiteToMove: true,
          nodeId: 9998,
          moveProbability: 0.5,
          cumulativeProbability: 0.1,
        );
        a.children.add(frontier);
        final map = FenMap()
          ..putCanonical(a.fen, a)
          ..putCanonical(b.fen, b); // canonical exists, leaf not registered
        final queue = FrontierQueue(bestFirst: false);

        addArrivalCumP(a, 0.2, 0.01, queue, fenMap: map);

        expect(frontier.cumulativeProbability, closeTo(0.2, 1e-12));
        expect(b.cumulativeProbability, 0.3);
        expect(queue.contains(frontier), isTrue);
      },
    );

    test('a repetition loop terminates', () {
      // A ─ p=1 ─ leaf with A's own position, registered against A.
      final a = nodeAt('A', cumP: 0.2);
      final back = BuildTreeNode(
        fen: a.fen,
        moveSan: 'x',
        moveUci: 'x',
        ply: 2,
        isWhiteToMove: true,
        nodeId: 9997,
        moveProbability: 1.0,
        cumulativeProbability: 0.2,
      )..explored = true;
      a.children.add(back);
      final map = FenMap()
        ..putCanonical(a.fen, a)
        ..addTransposition(back.fen, back);

      addArrivalCumP(
        a,
        0.1,
        0.01,
        FrontierQueue(bestFirst: false),
        fenMap: map,
      );

      expect(a.cumulativeProbability, closeTo(0.3, 1e-12));
      expect(back.cumulativeProbability, closeTo(0.3, 1e-12));
    });

    test('a non-positive delta is a no-op', () {
      final canonical = _node(cumP: 0.5);
      final queue = FrontierQueue(bestFirst: false);
      addArrivalCumP(canonical, 0.0, 0.01, queue);
      addArrivalCumP(canonical, -0.1, 0.01, queue);
      expect(canonical.cumulativeProbability, 0.5);
      expect(queue.isEmpty, isTrue);
    });
  });
}
