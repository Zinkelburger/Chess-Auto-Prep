import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:flutter_test/flutter_test.dart';

/// [OpeningTree.doesMoveTranspose] replaces the free function that used to
/// live in `utils/chess_move_utils.dart`, which linearly scanned and re-split
/// every key in `fenToNodes`. The index is already keyed by `normalizeFen`
/// (a 4-field FEN), so the lookup is O(1) and compares the same fields.
const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

/// Note the `-` en-passant field: dartchess only records an e.p. square when
/// a capture is actually available, and after 1.e4 no black pawn can take.
const afterE4Fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

/// Same position as [afterE4Fen] but with different move counters, so a naive
/// full-string comparison would miss it.
const afterE4DifferentClocks =
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 7 42';

/// Same board, but with the e.p. square spelled out. Some PGN/DB sources
/// write `e3` unconditionally where dartchess writes `-`.
const afterE4WithEpSquare =
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';

OpeningTree treeWith(String childFen) {
  final root = OpeningTreeNode(move: '', fen: startFen);
  final child = OpeningTreeNode(move: 'e4', fen: childFen, parent: root);
  root.children['e4'] = child;
  final tree = OpeningTree(root: root);
  tree.indexNode(root);
  tree.indexNode(child);
  return tree;
}

void main() {
  group('OpeningTree.doesMoveTranspose', () {
    test('detects a move landing on a covered position', () {
      final tree = treeWith(afterE4Fen);
      expect(tree.doesMoveTranspose(startFen, 'e4'), isTrue);
    });

    test('returns false for a move leaving covered territory', () {
      final tree = treeWith(afterE4Fen);
      expect(tree.doesMoveTranspose(startFen, 'd4'), isFalse);
    });

    test('ignores halfmove/fullmove counters when matching', () {
      // Position identity is the first four FEN fields only; the indexed node
      // carries clocks "7 42" while the played move produces "0 1".
      final tree = treeWith(afterE4DifferentClocks);
      expect(tree.doesMoveTranspose(startFen, 'e4'), isTrue);
    });

    test('returns false for illegal SAN in the position', () {
      final tree = treeWith(afterE4Fen);
      expect(tree.doesMoveTranspose(startFen, 'Nf6'), isFalse);
      expect(tree.doesMoveTranspose(startFen, 'xyz'), isFalse);
    });

    test('returns false for an unparsable fen', () {
      final tree = treeWith(afterE4Fen);
      expect(tree.doesMoveTranspose('not a fen', 'e4'), isFalse);
    });

    test('NOTE: the e.p. field is part of position identity', () {
      // Pre-existing behaviour, unchanged by the move off the old free
      // function — both compare the same four FEN fields. A tree indexed from
      // a source that always spells out the e.p. square will not match the
      // `-` that dartchess produces when no e.p. capture is legal. Pinned so
      // the asymmetry is visible if transposition recall ever looks low.
      final tree = treeWith(afterE4WithEpSquare);
      expect(tree.doesMoveTranspose(startFen, 'e4'), isFalse);
    });
  });
}
