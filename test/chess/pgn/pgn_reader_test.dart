import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_issue.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
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

  test('each glyph reads as its NAG', () {
    final tree = readGame('1. e4! e5? 2. Nf3!! Nc6?? 3. Bb5!? a6?! *').tree!;
    expect(
      [for (final node in tree.mainLine) node.nags.single],
      [1, 2, 3, 4, 5, 6],
    );
  });

  test('a tag name may hold digits and the punctuation exports use', () {
    final read = readGame(
      '[Opening2 "a"]\n[Score+ "b"]\n[Ply#Count "c"]\n[Time-Zone "d"]\n\n*',
    );
    expect(read.issues, isEmpty);
    expect(tagValue(read.tags, 'Opening2'), 'a');
    expect(tagValue(read.tags, 'Score+'), 'b');
    expect(tagValue(read.tags, 'Ply#Count'), 'c');
    expect(tagValue(read.tags, 'Time-Zone'), 'd');
  });

  test('a FEN nothing can play from is reported where its tag is', () {
    UnreadablePosition issue(String text) =>
        readGame(text).issues.whereType<UnreadablePosition>().single;
    final second = issue('[Event "x"]\n[FEN "not a fen"]\n\n1. e4 *');
    expect((second.line, second.column), (2, 1));
    final first = issue('\n[FEN "not a fen"]\n\n1. e4 *');
    expect((first.line, first.column), (2, 1));
  });

  test('the moves start past the header and the space after it', () {
    const text = '[Event "x"]\n\n1. e4 *';
    expect(movetextStart(text), text.indexOf('1.'));
  });

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
