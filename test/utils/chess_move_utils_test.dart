import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/utils/chess_move_utils.dart';
import 'package:flutter_test/flutter_test.dart';

const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

// After 1.e4:
const afterE4Fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

void main() {
  group('uciToSan', () {
    test('converts a normal move', () {
      expect(uciToSan(startFen, 'g1f3'), 'Nf3');
      expect(uciToSan(startFen, 'e2e4'), 'e4');
    });

    test('returns null for illegal or garbage input', () {
      expect(uciToSan(startFen, 'e2e5'), isNull);
      expect(uciToSan(startFen, 'zzzz'), isNull);
      expect(uciToSan('not a fen', 'e2e4'), isNull);
    });
  });

  group('sanToUci', () {
    test('converts a normal move', () {
      expect(sanToUci(startFen, 'Nf3'), 'g1f3');
      expect(sanToUci(startFen, 'e4'), 'e2e4');
    });

    test('returns null for illegal SAN', () {
      expect(sanToUci(startFen, 'Nf6'), isNull);
      expect(sanToUci(startFen, 'xyz'), isNull);
    });
  });

  group('uciPvToSan', () {
    test('converts a full PV', () {
      expect(uciPvToSan(startFen, ['e2e4', 'e7e5', 'g1f3']), [
        'e4',
        'e5',
        'Nf3',
      ]);
    });

    test('caps at maxPlies', () {
      expect(uciPvToSan(startFen, ['e2e4', 'e7e5', 'g1f3'], maxPlies: 2), [
        'e4',
        'e5',
      ]);
    });

    test('stops at first invalid move, keeping the prefix', () {
      expect(uciPvToSan(startFen, ['e2e4', 'e2e4', 'g1f3']), ['e4']);
    });

    test('empty on bad fen', () {
      expect(uciPvToSan('bad fen', ['e2e4']), isEmpty);
    });
  });

  group('doesMoveTranspose', () {
    test('detects transposition into a covered position', () {
      // Tree containing 1.e4 — reaching the after-e4 position via the tree.
      final tree = OpeningTreeBuilderTestHelper.singleLine();
      // From the start position, playing e4 lands on a covered node.
      expect(doesMoveTranspose(startFen, 'e4', tree), isTrue);
      // Playing d4 does not.
      expect(doesMoveTranspose(startFen, 'd4', tree), isFalse);
    });
  });
}

/// Minimal OpeningTree with root -> e4 for transposition tests.
class OpeningTreeBuilderTestHelper {
  static OpeningTree singleLine() {
    final root = OpeningTreeNode(move: '', fen: startFen);
    final e4 = OpeningTreeNode(move: 'e4', fen: afterE4Fen, parent: root);
    root.children['e4'] = e4;
    final tree = OpeningTree(root: root);
    tree.indexNode(root);
    tree.indexNode(e4);
    return tree;
  }
}
