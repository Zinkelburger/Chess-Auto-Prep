import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/move_tree.dart';

void main() {
  group('TreePath', () {
    test('empty path', () {
      const path = TreePath.empty;
      expect(path.isEmpty, true);
      expect(path.length, 0);
      expect(path.isMainline, true);
    });

    test('equality', () {
      final a = TreePath.from([0, 1, 0]);
      final b = TreePath.from([0, 1, 0]);
      final c = TreePath.from([0, 2, 0]);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('parent', () {
      final path = TreePath.from([0, 1, 2]);
      expect(path.parent, equals(TreePath.from([0, 1])));
      expect(TreePath.empty.parent, equals(TreePath.empty));
    });

    test('child', () {
      final path = TreePath.from([0, 1]);
      expect(path.child(3), equals(TreePath.from([0, 1, 3])));
    });

    test('isMainline', () {
      expect(TreePath.from([0, 0, 0]).isMainline, true);
      expect(TreePath.from([0, 1, 0]).isMainline, false);
    });

    test('isAncestorOf', () {
      final parent = TreePath.from([0, 1]);
      final child = TreePath.from([0, 1, 2]);
      final sibling = TreePath.from([0, 2]);
      expect(parent.isAncestorOf(child), true);
      expect(parent.isAncestorOf(parent), true);
      expect(child.isAncestorOf(parent), false);
      expect(parent.isAncestorOf(sibling), false);
    });

    test('take', () {
      final path = TreePath.from([0, 1, 2]);
      expect(path.take(2), equals(TreePath.from([0, 1])));
      expect(path.take(0), equals(TreePath.empty));
      expect(path.take(5), equals(path));
    });
  });

  group('MoveTree.fromMoves', () {
    test('builds linear tree from SAN list', () {
      final tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3', 'Nc6']);
      expect(tree.roots.length, 1);
      expect(tree.roots[0].san, 'e4');
      expect(tree.roots[0].children[0].san, 'e5');
      expect(tree.roots[0].children[0].children[0].san, 'Nf3');
      expect(tree.roots[0].children[0].children[0].children[0].san, 'Nc6');
    });

    test('each node has correct FEN', () {
      final tree = MoveTree.fromMoves(['e4', 'e5']);
      final e4 = tree.roots[0];
      // After 1. e4 it's black to move
      expect(e4.fen, contains(' b '));
      final e5 = e4.children[0];
      // After 1... e5 it's white to move
      expect(e5.fen, contains(' w '));
      // Both FENs should differ from the starting position
      expect(e4.fen, isNot(equals(tree.startingFen)));
      expect(e5.fen, isNot(equals(e4.fen)));
    });

    test('stops on invalid SAN', () {
      final tree = MoveTree.fromMoves(['e4', 'INVALID', 'e5']);
      expect(tree.roots.length, 1);
      expect(tree.roots[0].san, 'e4');
      expect(tree.roots[0].children, isEmpty);
    });

    test('empty moves creates empty tree', () {
      final tree = MoveTree.fromMoves([]);
      expect(tree.roots, isEmpty);
    });
  });

  group('MoveTree navigation', () {
    late MoveTree tree;

    setUp(() {
      tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']);
    });

    test('nodeAt returns correct node', () {
      expect(tree.nodeAt(TreePath.from([0]))?.san, 'e4');
      expect(tree.nodeAt(TreePath.from([0, 0]))?.san, 'e5');
      expect(tree.nodeAt(TreePath.from([0, 0, 0, 0, 0]))?.san, 'Bb5');
    });

    test('nodeAt returns null for empty path', () {
      expect(tree.nodeAt(TreePath.empty), null);
    });

    test('nodeAt returns null for invalid path', () {
      expect(tree.nodeAt(TreePath.from([1])), null);
      expect(tree.nodeAt(TreePath.from([0, 5])), null);
    });

    test('fenAt returns startingFen for empty path', () {
      expect(tree.fenAt(TreePath.empty), tree.startingFen);
    });

    test('fenAt returns node FEN for valid path', () {
      final fen = tree.fenAt(TreePath.from([0, 0]));
      expect(fen, tree.roots[0].children[0].fen);
    });

    test('sanSequenceAt returns SAN list', () {
      expect(
        tree.sanSequenceAt(TreePath.from([0, 0, 0])),
        ['e4', 'e5', 'Nf3'],
      );
    });

    test('sanSequenceAt empty path returns empty', () {
      expect(tree.sanSequenceAt(TreePath.empty), isEmpty);
    });

    test('nodeListAt returns ordered nodes', () {
      final nodes = tree.nodeListAt(TreePath.from([0, 0, 0]));
      expect(nodes.length, 3);
      expect(nodes.map((n) => n.san).toList(), ['e4', 'e5', 'Nf3']);
    });

    test('mainlineEndFrom walks to leaf', () {
      final end = tree.mainlineEndFrom(TreePath.empty);
      expect(end, equals(TreePath.from([0, 0, 0, 0, 0])));
      expect(tree.nodeAt(end)?.san, 'Bb5');
    });

    test('mainlineEndFrom from mid-path', () {
      final end = tree.mainlineEndFrom(TreePath.from([0, 0]));
      expect(end, equals(TreePath.from([0, 0, 0, 0, 0])));
    });

    test('isValidPath', () {
      expect(tree.isValidPath(TreePath.empty), true);
      expect(tree.isValidPath(TreePath.from([0])), true);
      expect(tree.isValidPath(TreePath.from([0, 0, 0, 0, 0])), true);
      expect(tree.isValidPath(TreePath.from([1])), false);
      expect(tree.isValidPath(TreePath.from([0, 0, 0, 0, 0, 0])), false);
    });
  });

  group('MoveTree mutation', () {
    test('addMove creates new child', () {
      final tree = MoveTree.fromMoves(['e4', 'e5']);
      final path = tree.addMove(TreePath.from([0, 0]), 'Nf3');
      expect(path, isNotNull);
      expect(tree.nodeAt(path!)?.san, 'Nf3');
    });

    test('addMove returns existing child if SAN matches', () {
      final tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      final path = tree.addMove(TreePath.from([0, 0]), 'Nf3');
      expect(path, equals(TreePath.from([0, 0, 0])));
      expect(tree.roots[0].children[0].children.length, 1);
    });

    test('addMove creates variation', () {
      final tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      final path = tree.addMove(TreePath.from([0, 0]), 'Bc4');
      expect(path, equals(TreePath.from([0, 0, 1])));
      expect(tree.roots[0].children[0].children.length, 2);
      expect(tree.roots[0].children[0].children[0].san, 'Nf3');
      expect(tree.roots[0].children[0].children[1].san, 'Bc4');
    });

    test('addMove at root (empty parent path)', () {
      final tree = MoveTree();
      final path = tree.addMove(TreePath.empty, 'e4');
      expect(path, equals(TreePath.from([0])));
      expect(tree.roots[0].san, 'e4');
    });

    test('addMove returns null for illegal move', () {
      final tree = MoveTree.fromMoves(['e4']);
      final path = tree.addMove(TreePath.from([0]), 'INVALID');
      expect(path, isNull);
    });

    test('deleteAt removes node', () {
      final tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      tree.deleteAt(TreePath.from([0, 0, 0]));
      expect(tree.roots[0].children[0].children, isEmpty);
    });

    test('deleteAt removes entire subtree', () {
      final tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3', 'Nc6']);
      tree.deleteAt(TreePath.from([0, 0]));
      expect(tree.roots[0].children, isEmpty);
    });

    test('promoteVariation moves to index 0', () {
      final tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      tree.addMove(TreePath.from([0, 0]), 'Bc4');
      tree.promoteVariation(TreePath.from([0, 0, 1]));
      expect(tree.roots[0].children[0].children[0].san, 'Bc4');
      expect(tree.roots[0].children[0].children[1].san, 'Nf3');
    });

    test('setComment updates node', () {
      final tree = MoveTree.fromMoves(['e4']);
      tree.setComment(TreePath.from([0]), 'King pawn opening');
      expect(tree.nodeAt(TreePath.from([0]))?.comment, 'King pawn opening');
    });

    test('toggleNag sets and clears a move-quality glyph', () {
      final tree = MoveTree.fromMoves(['e4']);
      final path = TreePath.from([0]);
      tree.toggleNag(path, 1);
      expect(tree.nodeAt(path)?.nags, [1]);
      // Quality NAGs are mutually exclusive — setting another replaces it.
      tree.toggleNag(path, 4);
      expect(tree.nodeAt(path)?.nags, [4]);
      // Toggling the active glyph removes it.
      tree.toggleNag(path, 4);
      expect(tree.nodeAt(path)?.nags, isNull);
    });
  });

  group('MoveTree PGN round-trip', () {
    test('fromPgn parses simple mainline', () {
      final tree = MoveTree.fromPgn('[Event "Test"]\n\n1. e4 e5 2. Nf3 Nc6');
      expect(tree.sanSequenceAt(tree.mainlineEndFrom(TreePath.empty)),
          ['e4', 'e5', 'Nf3', 'Nc6']);
    });

    test('fromPgn parses variations', () {
      final tree = MoveTree.fromPgn(
          '[Event "Test"]\n\n1. e4 e5 (1... c5 2. Nf3) 2. Nf3');
      expect(tree.roots[0].san, 'e4');
      final e4Children = tree.roots[0].children;
      expect(e4Children.length, 2);
      expect(e4Children[0].san, 'e5');
      expect(e4Children[1].san, 'c5');
      expect(e4Children[1].children[0].san, 'Nf3');
    });

    test('fromPgn preserves comments', () {
      final tree = MoveTree.fromPgn('[Event "Test"]\n\n1. e4 {Best move} e5');
      expect(tree.roots[0].comment, 'Best move');
    });

    test('NAG glyphs survive a serialize → parse round-trip', () {
      final tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      tree.toggleNag(TreePath.from([0]), 3); // e4!!
      tree.toggleNag(TreePath.from([0, 0]), 2); // e5?
      final reparsed = MoveTree.fromPgn(
          '[Event "Test"]\n\n${tree.toPgnMoveText()}');
      expect(reparsed.nodeAt(TreePath.from([0]))?.nags, contains(3));
      expect(reparsed.nodeAt(TreePath.from([0, 0]))?.nags, contains(2));
    });

    test('NAG glyphs survive on variations too', () {
      final tree = MoveTree.fromMoves(['e4', 'e5']);
      tree.addMove(TreePath.from([0]), 'c5'); // sideline
      tree.toggleNag(TreePath.from([0, 1]), 5); // c5!?
      final reparsed = MoveTree.fromPgn(
          '[Event "Test"]\n\n${tree.toPgnMoveText()}');
      expect(reparsed.roots[0].children[1].nags, contains(5));
    });

    test('fromPgn with FEN header', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      final tree = MoveTree.fromPgn('[FEN "$fen"]\n[SetUp "1"]\n\n1... e5');
      expect(tree.startingFen, fen);
      expect(tree.roots[0].san, 'e5');
    });

    test('toPgnMoveText produces valid move text', () {
      final tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3', 'Nc6']);
      final pgn = tree.toPgnMoveText();
      expect(pgn, contains('1. e4'));
      expect(pgn, contains('e5'));
      expect(pgn, contains('2. Nf3'));
      expect(pgn, contains('Nc6'));
    });

    test('round-trip: fromPgn → toPgn → fromPgn preserves structure', () {
      const original = '[Event "Test"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5';
      final tree1 = MoveTree.fromPgn(original);
      final pgn = tree1.toPgn(event: 'Test');
      final tree2 = MoveTree.fromPgn(pgn);

      final moves1 = tree1.sanSequenceAt(tree1.mainlineEndFrom(TreePath.empty));
      final moves2 = tree2.sanSequenceAt(tree2.mainlineEndFrom(TreePath.empty));
      expect(moves2, equals(moves1));
    });

    test('round-trip with variations', () {
      const original = '[Event "Test"]\n\n1. e4 e5 (1... c5 2. Nf3) 2. Nf3';
      final tree1 = MoveTree.fromPgn(original);
      final pgn = tree1.toPgnMoveText();

      final tree2 = MoveTree.fromPgn('[Event "RT"]\n\n$pgn');
      expect(tree2.roots[0].children.length, 2);
      expect(tree2.roots[0].children[0].san, 'e5');
      expect(tree2.roots[0].children[1].san, 'c5');
    });

    test('round-trip with comments', () {
      const original = '[Event "Test"]\n\n1. e4 {Best} e5 {Solid}';
      final tree = MoveTree.fromPgn(original);
      final pgn = tree.toPgnMoveText();
      expect(pgn, contains('{Best}'));
      expect(pgn, contains('{Solid}'));
    });

    test('toPgn includes FEN header for non-standard start', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      final tree = MoveTree.fromMoves(['e5'], startingFen: fen);
      final pgn = tree.toPgn();
      expect(pgn, contains('[FEN "$fen"]'));
      expect(pgn, contains('[SetUp "1"]'));
    });

    test('empty tree produces empty move text', () {
      final tree = MoveTree();
      expect(tree.toPgnMoveText(), '');
    });

    test('fromPgn handles empty string', () {
      final tree = MoveTree.fromPgn('');
      expect(tree.isEmpty, true);
    });

    test('fromPgn handles malformed PGN gracefully', () {
      final tree = MoveTree.fromPgn('this is not valid pgn');
      expect(tree.isEmpty, true);
    });
  });
}
