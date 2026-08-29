import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// The cursor and walk APIs that the repertoire screen leans on per keypress:
/// [OpeningTree.advance] (one FEN per *new* node), [OpeningTree.syncToFens]
/// (no dartchess replay when the caller already holds the FENs) and the
/// pure [OpeningTree.hasMoveOnPath].
void main() {
  /// FENs after each ply of [sans] from the standard start.
  List<String> fensAfter(List<String> sans) {
    Position pos = Chess.initial;
    return [for (final san in sans) (pos = pos.play(pos.parseSan(san)!)).fen];
  }

  OpeningTree treeWithLines(List<List<String>> lines) {
    final tree = OpeningTree();
    for (final line in lines) {
      tree.appendLine(line);
    }
    return tree;
  }

  group('advance', () {
    test('creates and indexes a child once, then returns the same node', () {
      final tree = OpeningTree();
      final pos = Chess.initial.play(Chess.initial.parseSan('e4')!);

      final first = tree.advance(tree.root, 'e4', pos);
      final second = tree.advance(tree.root, 'e4', pos);

      expect(identical(first, second), isTrue);
      expect(tree.root.children['e4'], same(first));
      expect(tree.fenToNodes[normalizeFen(pos.fen)], [first]);
    });

    test('a second path into the same position indexes a second node', () {
      final tree = treeWithLines([
        ['d4', 'Nf6', 'Nf3', 'd5'],
        ['Nf3', 'd5', 'd4', 'Nf6'],
      ]);
      final key = normalizeFen(fensAfter(['d4', 'Nf6', 'Nf3', 'd5']).last);
      expect(tree.fenToNodes[key], hasLength(2));
    });
  });

  group('syncToFens', () {
    test('agrees with syncToMoveHistory on a book line', () {
      final tree = treeWithLines([
        ['e4', 'e5', 'Nf3', 'Nc6'],
      ]);
      const sans = ['e4', 'e5', 'Nf3'];

      tree.syncToMoveHistory(sans);
      final viaReplay = tree.currentNode;

      expect(tree.syncToFens(sans, fensAfter(sans)), isTrue);
      expect(tree.currentNode, same(viaReplay));
      expect(tree.currentMovePath, sans);
      expect(tree.inBook, isTrue);
    });

    test('follows a transposition into a node reached by another order', () {
      final tree = treeWithLines([
        ['d4', 'Nf6', 'Nf3', 'd5'],
      ]);
      const sans = ['Nf3', 'd5', 'd4', 'Nf6'];

      expect(tree.syncToFens(sans, fensAfter(sans)), isTrue);
      expect(tree.currentNode.getMovePath(), ['d4', 'Nf6', 'Nf3', 'd5']);
      expect(tree.currentMovePath, sans);
    });

    test('goes off book and keeps the board FEN when the line leaves', () {
      final tree = treeWithLines([
        ['e4', 'e5'],
      ]);
      const sans = ['e4', 'e5', 'Nf3', 'Nc6'];
      final fens = fensAfter(sans);

      expect(tree.syncToFens(sans, fens), isFalse);
      expect(tree.inBook, isFalse);
      expect(tree.currentFen, fens.last);
      expect(tree.currentMovePath, sans);
    });

    test('an empty path resets to the root', () {
      final tree = treeWithLines([
        ['e4'],
      ]);
      tree.makeMove('e4');
      expect(tree.syncToFens(const [], const []), isTrue);
      expect(tree.currentNode, same(tree.root));
      expect(tree.currentFen, kStandardStartFen);
    });
  });

  group('hasMoveOnPath', () {
    test('answers without moving the cursor', () {
      final tree = treeWithLines([
        ['e4', 'e5', 'Nf3'],
        ['d4', 'd5'],
      ]);
      tree.makeMove('d4');

      expect(tree.hasMoveOnPath(['e4', 'e5'], 'Nf3'), isTrue);
      expect(tree.hasMoveOnPath(['e4', 'e5'], 'Bc4'), isFalse);
      expect(tree.hasMoveOnPath(['e4', 'c5'], 'Nf3'), isFalse);

      expect(tree.currentNode.move, 'd4');
      expect(tree.currentMovePath, ['d4']);
    });

    test('walks through a transposition like makeMove does', () {
      final tree = treeWithLines([
        ['d4', 'Nf6', 'Nf3', 'd5', 'c4'],
        ['Nf3', 'd5', 'd4'],
      ]);
      // 3...Nf6 was never played after 1.Nf3 d5 2.d4, but it lands on the
      // first line's position, whose continuation is c4.
      expect(tree.hasMoveOnPath(['Nf3', 'd5', 'd4', 'Nf6'], 'c4'), isTrue);
      // A path whose intermediate position is unknown leaves the book.
      expect(tree.hasMoveOnPath(['c4', 'd5', 'd4', 'Nf6'], 'c4'), isFalse);
    });
  });

  group('continuationsAt', () {
    test('offers a one-ply transposition with its SAN from this position', () {
      final tree = treeWithLines([
        ['d4', 'Nf6', 'e3', 'c5'],
      ]);
      final fen = fensAfter(['d4', 'c5', 'e3']).last;

      final moves = tree.continuationsAt(fen).map((g) => g.move).toList();
      expect(moves, contains('Nf6'));
      final group = tree
          .continuationsAt(fen)
          .firstWhere((g) => g.move == 'Nf6');
      expect(group.viaTransposition, isTrue);
    });

    test('is stable across repeated reads of the same position', () {
      final tree = treeWithLines([
        ['e4', 'e5'],
        ['e4', 'c5'],
      ]);
      final fen = fensAfter(['e4']).last;
      final first = tree.continuationsAt(fen).map((g) => g.move).toList();
      final again = tree.continuationsAt(fen).map((g) => g.move).toList();
      expect(again, first);
      expect(first, ['e5', 'c5']);
    });
  });
}
