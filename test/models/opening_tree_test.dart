import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';

void main() {
  group('OpeningTree', () {
    late OpeningTree tree;
    late OpeningTreeNode root;

    setUp(() {
      // Create a test tree with some branches
      root = OpeningTreeNode(
        move: '',
        fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      );

      // Add first-level moves: e4 and d4
      final e4Node = root.getOrCreateChild(
        'e4',
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
      );
      e4Node.updateStats(1.0); // Win for e4

      final d4Node = root.getOrCreateChild(
        'd4',
        'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1',
      );
      d4Node.updateStats(0.5); // Draw for d4

      // Add second-level moves after e4
      final e5Node = e4Node.getOrCreateChild(
        'e5',
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2',
      );
      e5Node.updateStats(1.0);

      final c5Node = e4Node.getOrCreateChild(
        'c5',
        'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2',
      );
      c5Node.updateStats(0.5);

      // Add third-level move: Nf3 after e4 e5
      final nf3Node = e5Node.getOrCreateChild(
        'Nf3',
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2',
      );
      nf3Node.updateStats(1.0);

      tree = OpeningTree(root: root);

      // Index all nodes for FEN lookups
      void indexNodesRecursive(OpeningTreeNode node) {
        tree.indexNode(node);
        for (final child in node.children.values) {
          indexNodesRecursive(child);
        }
      }

      indexNodesRecursive(root);
    });

    group('Basic Navigation', () {
      test('starts at root', () {
        expect(tree.currentNode, equals(root));
        expect(tree.currentDepth, equals(0));
      });

      test('makeMove navigates to child', () {
        final success = tree.makeMove('e4');
        expect(success, isTrue);
        expect(tree.currentNode.move, equals('e4'));
        expect(tree.currentDepth, equals(1));
      });

      test('makeMove returns false for non-existent move', () {
        final success = tree.makeMove('e3');
        expect(success, isFalse);
        expect(tree.currentNode, equals(root));
      });

      test('goBack navigates to parent', () {
        tree.makeMove('e4');
        final success = tree.goBack();
        expect(success, isTrue);
        expect(tree.currentNode, equals(root));
      });

      test('goBack at root returns false', () {
        final success = tree.goBack();
        expect(success, isFalse);
        expect(tree.currentNode, equals(root));
      });

      test('reset returns to root', () {
        tree.makeMove('e4');
        tree.makeMove('e5');
        tree.reset();
        expect(tree.currentNode, equals(root));
        expect(tree.currentDepth, equals(0));
      });
    });

    group('syncToMoveHistory', () {
      test('syncs to empty move list (root)', () {
        tree.makeMove('e4');
        tree.makeMove('e5');

        final success = tree.syncToMoveHistory([]);
        expect(success, isTrue);
        expect(tree.currentNode, equals(root));
        expect(tree.currentDepth, equals(0));
      });

      test('syncs to single move', () {
        final success = tree.syncToMoveHistory(['e4']);
        expect(success, isTrue);
        expect(tree.currentNode.move, equals('e4'));
        expect(tree.currentDepth, equals(1));
      });

      test('syncs to multiple moves', () {
        final success = tree.syncToMoveHistory(['e4', 'e5', 'Nf3']);
        expect(success, isTrue);
        expect(tree.currentNode.move, equals('Nf3'));
        expect(tree.currentDepth, equals(3));
      });

      test('syncs to partial path when move not in tree', () {
        final success = tree.syncToMoveHistory(['e4', 'e5', 'Nf3', 'Nc6']);
        expect(success, isFalse);
        // Should stop at Nf3 (last valid move)
        expect(tree.currentNode.move, equals('Nf3'));
        expect(tree.currentDepth, equals(3));
      });

      test('stops at first invalid move', () {
        final success = tree.syncToMoveHistory(['e4', 'Ke2', 'Nf3']);
        expect(success, isFalse);
        // Should stop at e4 (last valid move before Ke2)
        expect(tree.currentNode.move, equals('e4'));
        expect(tree.currentDepth, equals(1));
      });

      test('syncs to different branch', () {
        tree.syncToMoveHistory(['e4', 'e5']);

        // Now sync to a different branch
        final success = tree.syncToMoveHistory(['e4', 'c5']);
        expect(success, isTrue);
        expect(tree.currentNode.move, equals('c5'));
        expect(tree.currentDepth, equals(2));
      });

      test('syncs to alternative first move', () {
        tree.syncToMoveHistory(['e4']);

        // Now sync to d4
        final success = tree.syncToMoveHistory(['d4']);
        expect(success, isTrue);
        expect(tree.currentNode.move, equals('d4'));
        expect(tree.currentDepth, equals(1));
      });

      test('preserves tree state after failed sync', () {
        tree.syncToMoveHistory(['e4', 'e5']);

        // Try to sync to invalid path
        tree.syncToMoveHistory(['e4', 'invalid']);

        // Should be at e4 (last valid)
        expect(tree.currentNode.move, equals('e4'));
        expect(tree.currentDepth, equals(1));
      });
    });

    group('Move Path', () {
      test('getMovePath returns empty list at root', () {
        expect(root.getMovePath(), isEmpty);
      });

      test('getMovePath returns correct path', () {
        tree.makeMove('e4');
        tree.makeMove('e5');
        tree.makeMove('Nf3');

        final path = tree.currentNode.getMovePath();
        expect(path, equals(['e4', 'e5', 'Nf3']));
      });

      test('getMovePathString formats correctly', () {
        tree.makeMove('e4');
        tree.makeMove('e5');
        tree.makeMove('Nf3');

        final pathString = tree.currentNode.getMovePathString();
        expect(pathString, equals('1.e4 e5 2.Nf3'));
      });

      test('getMovePathString handles single move', () {
        tree.makeMove('e4');
        final pathString = tree.currentNode.getMovePathString();
        expect(pathString, equals('1.e4'));
      });
    });

    group('Statistics', () {
      test('win rate is calculated correctly', () {
        final node = OpeningTreeNode(move: 'e4', fen: 'test');
        node.wins = 5;
        node.draws = 2;
        node.losses = 3;
        node.gamesPlayed = 10;

        // Win rate = (5 + 0.5 * 2) / 10 = 6 / 10 = 0.6
        expect(node.winRate, closeTo(0.6, 0.001));
        expect(node.winRatePercent, closeTo(60.0, 0.1));
      });

      test('win rate is 0 when no games', () {
        final node = OpeningTreeNode(move: 'e4', fen: 'test');
        expect(node.winRate, equals(0.0));
        expect(node.winRatePercent, equals(0.0));
      });

      test('updateStats increments correctly for win', () {
        final node = OpeningTreeNode(move: 'e4', fen: 'test');
        node.updateStats(1.0);

        expect(node.gamesPlayed, equals(1));
        expect(node.wins, equals(1));
        expect(node.draws, equals(0));
        expect(node.losses, equals(0));
      });

      test('updateStats increments correctly for draw', () {
        final node = OpeningTreeNode(move: 'e4', fen: 'test');
        node.updateStats(0.5);

        expect(node.gamesPlayed, equals(1));
        expect(node.wins, equals(0));
        expect(node.draws, equals(1));
        expect(node.losses, equals(0));
      });

      test('updateStats increments correctly for loss', () {
        final node = OpeningTreeNode(move: 'e4', fen: 'test');
        node.updateStats(0.0);

        expect(node.gamesPlayed, equals(1));
        expect(node.wins, equals(0));
        expect(node.draws, equals(0));
        expect(node.losses, equals(1));
      });

      test('sortedChildren returns in descending games order', () {
        final sorted = root.sortedChildren;
        expect(sorted.length, equals(2));
        // e4 has more games than d4
        expect(sorted[0].move, equals('e4'));
        expect(sorted[1].move, equals('d4'));
      });
    });

    group('navigateToFen', () {
      test('navigates to FEN in tree', () {
        const e4Fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
        final success = tree.navigateToFen(e4Fen);

        expect(success, isTrue);
        expect(tree.currentNode.move, equals('e4'));
      });

      test('returns false for FEN not in tree', () {
        // A FEN that looks valid but isn't in our test tree
        const invalidFen = 'rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq d6 0 2';
        final success = tree.navigateToFen(invalidFen);

        expect(success, isFalse);
      });
    });
  });
}
