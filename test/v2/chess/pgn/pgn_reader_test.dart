import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'reads moves, variations, comments and NAGs with the position after each',
    () {
      final read = readGame('1. e4 e5 (1... c5!? {Sicilian}) 2. Nf3 *');
      expect(read.issues, isEmpty);
      final tree = read.tree!;
      expect(tree.rootFen, Fen.initial);

      final e4 = tree.children.single;
      expect(e4.san, 'e4');
      expect(e4.uci, 'e2e4');
      expect(e4.fen.whiteToMove, isFalse);

      final [e5, c5] = e4.children;
      expect(e5.san, 'e5');
      expect(c5.san, 'c5');
      expect(c5.nags, [5]);
      expect(c5.comment, 'Sicilian');
      expect(e5.children.single.san, 'Nf3');
    },
  );

  test('starts from the FEN header', () {
    final read = readGame('''
[FEN "8/8/8/8/8/8/8/K6k w - - 0 1"]

1. Kb1 *
''');
    expect(read.tree!.children.single.uci, 'a1b1');
  });

  group('move numbers', () {
    test('are read however they are spaced', () {
      for (final game in const [
        '1.e4 e5 2.Nf3 *',
        '1. e4 e5 2. Nf3 *',
        '1. e4 1... e5 2. Nf3 *',
        '1. e4 1. ... e5 2. Nf3 *',
        '1.e4 1...e5 2.Nf3 *',
      ]) {
        expect(mainlineSans(readGame(game).tree!), [
          'e4',
          'e5',
          'Nf3',
        ], reason: game);
      }
    });

    test('do not say whose move it is', () {
      // A course that numbers Black's ply with a single dot, which is the
      // commonest repertoire export on this machine.
      final read = readGame('1. e4\n1. e5\n2. Nf3\n2. Nc6\n*');
      expect(mainlineSans(read.tree!), ['e4', 'e5', 'Nf3', 'Nc6']);
      expect(read.issues, isEmpty);
    });

    test('a five-digit number is a number, not a null move', () {
      // `0000` spells a ply where nobody moved, so a reader that looks for
      // words before numbers turns move ten thousand into one.
      final read = readGame('10000. e4 10000... e5 *');
      expect(mainlineSans(read.tree!), ['e4', 'e5']);
      expect(read.issues, isEmpty);
    });
  });
}
