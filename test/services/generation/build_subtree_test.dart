import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
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

  group('copyNodeAnalysis', () {
    BuildTreeNode node(String uci) => BuildTreeNode(
      fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
      moveSan: 'e4',
      moveUci: uci,
      ply: 1,
      isWhiteToMove: false,
      nodeId: 1,
    );

    test('copies analysis values and database stats', () {
      final from = node('e2e4')
        ..engineEvalCp = 35
        ..explored = true
        ..pruneReason = PruneReason.evalTooLow
        ..pruneEvalCp = -300
        ..openingName = "King's Pawn"
        ..openingEco = 'B00'
        ..maiaFrequency = 0.42
        ..pvContinuationMove = 'e7e5'
        ..engineInjected = true
        ..extEvalMode = ExtEvalMode.skipExternal
        ..ease = 0.7
        ..localCpl = 12.5
        ..expectimaxValue = 0.61
        ..hasExpectimax = true
        ..opponentEase = 0.3
        ..trapScore = 0.05
        ..myEase = 0.8;
      from.setLichessStats(10, 5, 3);
      final into = node('e2e4');

      copyNodeAnalysis(into, from: from);

      expect(into.engineEvalCp, 35);
      expect(into.explored, isTrue);
      expect(into.pruneReason, PruneReason.evalTooLow);
      expect(into.pruneEvalCp, -300);
      expect(into.openingName, "King's Pawn");
      expect(into.openingEco, 'B00');
      expect(into.maiaFrequency, 0.42);
      expect(into.pvContinuationMove, 'e7e5');
      expect(into.engineInjected, isTrue);
      expect(into.extEvalMode, ExtEvalMode.skipExternal);
      expect(into.ease, 0.7);
      expect(into.localCpl, 12.5);
      expect(into.expectimaxValue, 0.61);
      expect(into.hasExpectimax, isTrue);
      expect(into.opponentEase, 0.3);
      expect(into.trapScore, 0.05);
      expect(into.myEase, 0.8);
      expect(into.whiteWins, 10);
      expect(into.blackWins, 5);
      expect(into.draws, 3);
      expect(into.totalGames, 18);
    });

    test('leaves structure, Pure fields, selection and PV to the caller', () {
      final from = node('e2e4')
        ..historyAware = true
        ..terminalValue = 0.5
        ..isRepertoireMove = true
        ..enginePv = const ['e7e5', 'g1f3'];
      final into = node('e2e4');

      copyNodeAnalysis(into, from: from);

      expect(into.historyAware, isFalse);
      expect(into.terminalValue, isNull);
      expect(into.isRepertoireMove, isFalse);
      expect(into.enginePv, isEmpty);
      expect(into.parent, isNull);
      expect(into.children, isEmpty);
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
