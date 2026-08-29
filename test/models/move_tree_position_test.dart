import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// [MoveNode.position] / [MoveTree.positionAt] give navigation a parsed
/// position without re-reading the FEN, and [MoveTree.version] lets views
/// keep derived work across cursor moves.
void main() {
  group('positions', () {
    test('a node built by playing a move carries that position', () {
      final tree = MoveTree.fromMoves(['e4', 'e5', 'Nf3']);
      final node = tree.nodeAt(const TreePath([0, 0, 0]))!;

      expect(node.position.fen, node.fen);
      expect(node.position.turn, Side.black);
      expect(identical(node.position, node.position), isTrue);
    });

    test('a node given only a FEN parses it lazily, once', () {
      const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      final node = MoveNode(san: 'e4', fen: fen);

      final first = node.position;
      expect(first.fen, fen);
      expect(identical(first, node.position), isTrue);
    });

    test('positionAt walks the tree instead of parsing', () {
      final tree = MoveTree.fromPgn('1. d4 d5 (1... Nf6 2. c4) 2. c4');

      expect(tree.positionAt(TreePath.empty), same(tree.startingPosition));
      expect(
        tree.positionAt(const TreePath([0, 1, 0])).fen,
        tree.fenAt(const TreePath([0, 1, 0])),
      );
      expect(tree.positionAt(const TreePath([7])), same(tree.startingPosition));
    });

    test('changing the starting FEN re-derives the starting position', () {
      final tree = MoveTree();
      final before = tree.startingPosition;
      tree.startingFen =
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      expect(tree.startingPosition.turn, Side.black);
      expect(identical(before, tree.startingPosition), isFalse);
    });

    test('addMove derives the child from the parent position', () {
      final tree = MoveTree.fromMoves(['e4']);
      final path = tree.addMove(const TreePath([0]), 'e5')!;
      final node = tree.nodeAt(path)!;
      expect(node.position.fen, node.fen);
      expect(node.fen, startsWith('rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP'));
    });

    test('a node whose FEN will not parse refuses to grow a child', () {
      // The display getter substitutes the initial board so a board always
      // has something to draw; deriving a *new* node from that substitute
      // would append a child belonging to a completely different position.
      final tree = MoveTree();
      tree.roots.add(MoveNode(san: '??', fen: 'not a fen'));

      expect(tree.positionAt(const TreePath([0])), tree.startingPosition);
      expect(tree.positionOrNullAt(const TreePath([0])), isNull);
      expect(tree.addMove(const TreePath([0]), 'e5'), isNull);
      expect(tree.nodeAt(const TreePath([0]))!.children, isEmpty);
    });

    test('an unparseable starting FEN refuses a root move', () {
      final tree = MoveTree()..startingFen = 'nonsense';

      expect(tree.startingPositionOrNull, isNull);
      expect(tree.startingPosition, Chess.initial);
      expect(tree.addMove(TreePath.empty, 'e4'), isNull);
      expect(tree.roots, isEmpty);
    });

    test('an illegal SAN at a good position is still refused', () {
      final tree = MoveTree.fromMoves(['e4']);
      expect(tree.addMove(const TreePath([0]), 'Qh8'), isNull);
    });
  });

  group('version', () {
    test('bumps on every mutation and not on reads', () {
      final tree = MoveTree.fromMoves(['e4', 'e5']);
      final v0 = tree.version;

      tree.nodeAt(const TreePath([0, 0]));
      tree.fenAt(const TreePath([0, 0]));
      tree.sanSequenceAt(const TreePath([0, 0]));
      expect(tree.version, v0);

      tree.addMove(const TreePath([0, 0]), 'Nf3');
      expect(tree.version, v0 + 1);

      // Re-adding an existing move is a lookup, not a mutation.
      tree.addMove(const TreePath([0, 0]), 'Nf3');
      expect(tree.version, v0 + 1);

      tree.setComment(const TreePath([0]), 'Best by test.');
      expect(tree.version, v0 + 2);
      tree.setComment(const TreePath([0]), 'Best by test.');
      expect(tree.version, v0 + 2);

      tree.toggleNag(const TreePath([0]), 1);
      expect(tree.version, v0 + 3);

      tree.addMove(const TreePath([0]), 'c5');
      tree.promoteVariation(const TreePath([0, 1]));
      expect(tree.version, v0 + 5);

      tree.deleteAt(const TreePath([0, 0]));
      expect(tree.version, v0 + 6);

      tree.markMutated();
      expect(tree.version, v0 + 7);
    });
  });
}
