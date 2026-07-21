import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';

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
        const e4Fen =
            'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
        final success = tree.navigateToFen(e4Fen);

        expect(success, isTrue);
        expect(tree.currentNode.move, equals('e4'));
      });

      test('returns false for FEN not in tree', () {
        // A FEN that looks valid but isn't in our test tree
        const invalidFen =
            'rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq d6 0 2';
        final success = tree.navigateToFen(invalidFen);

        expect(success, isFalse);
      });
    });

    group('hasMove', () {
      test('returns true when SAN exists at FEN', () {
        const e4Fen =
            'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
        expect(tree.hasMove(root.fen, 'e4'), isTrue);
        expect(tree.hasMove(e4Fen, 'e5'), isTrue);
      });

      test('returns false for unexplored move', () {
        const e4Fen =
            'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
        expect(tree.hasMove(e4Fen, 'a6'), isFalse);
        expect(tree.hasMove(root.fen, 'a4'), isFalse);
      });
    });

    group('Transpositions', () {
      // Mirrors the real-world discrepancy this guards against: a position
      // reached via two move orders (1 game on path A, 2 games on path B)
      // must present 3 games and both continuations, not just path A's.
      late OpeningTree transTree;
      late OpeningTreeNode viaA;
      late OpeningTreeNode viaB;
      const sharedFen = 'shared/pos w KQkq - 0 5';

      setUp(() {
        final transRoot = OpeningTreeNode(move: '', fen: 'start w KQkq - 0 1');
        transTree = OpeningTree(root: transRoot);

        // Path A (1 game, loss): a1 → x → Bd3
        final a1 = transRoot.getOrCreateChild('a1', 'afen b KQkq - 0 1');
        viaA = a1.getOrCreateChild('x', sharedFen);
        final bd3 = viaA.getOrCreateChild('Bd3', 'bd3fen b KQkq - 0 5');
        for (final node in [transRoot, a1, viaA, bd3]) {
          node.updateStats(0.0);
        }

        // Path B (2 games, losses): b1 → y → Qd2
        final b1 = transRoot.getOrCreateChild('b1', 'bfen b KQkq - 0 1');
        viaB = b1.getOrCreateChild('y', sharedFen);
        final qd2 = viaB.getOrCreateChild('Qd2', 'qd2fen b KQkq - 0 5');
        for (var game = 0; game < 2; game++) {
          for (final node in [transRoot, b1, viaB, qd2]) {
            node.updateStats(0.0);
          }
        }

        void indexRecursive(OpeningTreeNode node) {
          transTree.indexNode(node);
          for (final child in node.children.values) {
            indexRecursive(child);
          }
        }

        indexRecursive(transRoot);
      });

      test('indexNode is idempotent', () {
        final key = normalizeFen(sharedFen);
        final before = transTree.fenToNodes[key]!.length;
        transTree.indexNode(viaA);
        expect(transTree.fenToNodes[key]!.length, equals(before));
      });

      test('groupFor sums stats across move orders', () {
        final group = transTree.groupFor(viaA);
        expect(group.nodes.length, equals(2));
        expect(group.gamesPlayed, equals(3));
        expect(group.losses, equals(3));
        expect(group.winRate, equals(0.0));
      });

      test('groupFor falls back to the node itself when unindexed', () {
        final orphan = OpeningTreeNode(move: 'z', fen: 'orphan w - - 0 1');
        final group = transTree.groupFor(orphan);
        expect(group.nodes, equals([orphan]));
      });

      test('group children merge continuations from all move orders', () {
        final moves = transTree.groupFor(viaA).children;
        expect(moves.map((m) => m.move).toList(), equals(['Qd2', 'Bd3']));
        expect(moves.first.gamesPlayed, equals(2));
        expect(moves.last.gamesPlayed, equals(1));
      });

      test('navigateToFen lands on the most-played path', () {
        expect(transTree.navigateToFen(sharedFen), isTrue);
        expect(transTree.currentNode, same(viaB));
      });

      test('makeMove follows a continuation from another move order', () {
        transTree.navigateToFen(sharedFen); // Cursor on viaB (no Bd3 child).
        expect(transTree.makeMove('Bd3'), isTrue);
        expect(transTree.currentNode.move, equals('Bd3'));
        expect(transTree.currentNode.getMovePath(), equals(['a1', 'x', 'Bd3']));
      });
    });

    group('appendLineFromFen', () {
      test('adds new branch from standard start', () {
        tree.appendLineFromFen(root.fen, ['a4']);
        expect(tree.hasMove(root.fen, 'a4'), isTrue);
      });

      test('extends existing line from indexed FEN', () {
        tree.syncToMoveHistory(['e4', 'e5']);
        final fen = tree.currentNode.fen;
        expect(tree.hasMove(fen, 'Bc4'), isFalse);
        tree.appendLineFromFen(fen, ['Bc4']);
        expect(tree.hasMove(fen, 'Bc4'), isTrue);
      });
    });
  });

  group('reachEstimate', () {
    // 10 games: White always plays 1.e4 (10/10). Black answers 1...e5 in 6
    // and 1...c5 in 4. After 1...e5, White plays 2.Nf3 in 4 and 2.f4 in 2.
    late OpeningTreeNode root;
    late OpeningTreeNode e4;
    late OpeningTreeNode e5;
    late OpeningTreeNode nf3;
    late OpeningTreeNode f4;

    void addGames(OpeningTreeNode node, int count) {
      for (var i = 0; i < count; i++) {
        node.updateStats(0.5);
      }
    }

    setUp(() {
      root = OpeningTreeNode(
        move: '',
        fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      );
      e4 = root.getOrCreateChild(
        'e4',
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
      );
      e5 = e4.getOrCreateChild(
        'e5',
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2',
      );
      final c5 = e4.getOrCreateChild(
        'c5',
        'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2',
      );
      nf3 = e5.getOrCreateChild(
        'Nf3',
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2',
      );
      f4 = e5.getOrCreateChild(
        'f4',
        'rnbqkbnr/pppp1ppp/8/4p3/4PP2/8/PPPP2PP/RNBQKBNR b KQkq f3 0 2',
      );
      addGames(root, 10);
      addGames(e4, 10);
      addGames(e5, 6);
      addGames(c5, 4);
      addGames(nf3, 4);
      addGames(f4, 2);
    });

    test('root position is certain with no decisions', () {
      final est = root.reachEstimate(protagonistIsWhite: true);
      expect(est.probability, equals(1.0));
      expect(est.decisionPoints, equals(0));
    });

    test('white protagonist: only White\'s choices multiply', () {
      // 1.e4 was 10/10 (no decision); 1...e5 is Black's move (free for the
      // viewer); 2.Nf3 was 4/6 — the only real decision point.
      final est = nf3.reachEstimate(protagonistIsWhite: true);
      expect(est.probability, closeTo(4 / 6, 1e-9));
      expect(est.decisionPoints, equals(1));
    });

    test('black protagonist: only Black\'s choices multiply', () {
      // 1...e5 was 6/10; White's 1.e4 and 2.Nf3 count as certain.
      final est = nf3.reachEstimate(protagonistIsWhite: false);
      expect(est.probability, closeTo(0.6, 1e-9));
      expect(est.decisionPoints, equals(1));
    });

    test('unanimous move is not a decision point', () {
      final est = e4.reachEstimate(protagonistIsWhite: true);
      expect(est.probability, equals(1.0));
      expect(est.decisionPoints, equals(0));
    });

    test('PositionGroup sums probabilities across paths', () {
      // Not a real transposition, but exercises the summing contract:
      // 4/6 + 2/6 covers every White continuation after 1.e4 e5.
      final est = PositionGroup([
        nf3,
        f4,
      ]).reachEstimate(protagonistIsWhite: true);
      expect(est.probability, closeTo(1.0, 1e-9));
      // Decision points come from the most-played path (Nf3).
      expect(est.decisionPoints, equals(1));
    });

    test('percentLabel formats extremes readably', () {
      expect(const ReachEstimate(1.0, 0).percentLabel, equals('100'));
      expect(const ReachEstimate(0.0004, 3).percentLabel, equals('<0.1'));
      expect(const ReachEstimate(0.345, 2).percentLabel, equals('34.5'));
      expect(const ReachEstimate(0.0, 0).percentLabel, equals('0.0'));
    });
  });
}
