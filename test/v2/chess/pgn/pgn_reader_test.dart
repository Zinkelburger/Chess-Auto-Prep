import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
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

  test('an illegal move ends its branch and is reported', () {
    final read = readGame('1. e4 e5 2. Ke3 Nf6 (2... Qh4) *');
    expect(read.tree!.children.single.children.single.children, isEmpty);
    expect(read.issues, ['Ke3 is not legal']);
  });

  test('an unusable FEN leaves the game unread', () {
    final read = readGame('''
[FEN "not a fen"]

1. e4 *
''');
    expect(read.tree, isNull);
    expect(read.issues, ['unusable FEN header']);
  });

  test('a comment holding a blank line does not cut the game short', () {
    final read = readGame('''
[Event "Notes"]
[Result "*"]

1. e4 {A thought that runs on

[%eval 0.21]} d5 2. c4 *
''');
    final e4 = read.tree!.children.single;
    expect(e4.children.single.san, 'd5');
    expect(e4.children.single.children.single.san, 'c4');
  });
}
