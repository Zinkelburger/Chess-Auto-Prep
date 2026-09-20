import 'package:chess_auto_prep/v2/chess/pgn/pgn_issue.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart';
import 'package:flutter_test/flutter_test.dart';

/// Games whose braces do not balance line by line, which is every game a
/// comment runs past the end of a line in.
const _braceInside = '1. e4 {see {this} *';
const _braceInsideComment = 'see {this';
const _neverClosed = '1. e4 {never ends';
const _runsOn =
    '[Event "Notes"]\n'
    '[Result "*"]\n'
    '\n'
    '1. e4 {A thought that runs on\n'
    '\n'
    '[%eval 0.21]} d5 2. c4 *\n';

void main() {
  group('comments', () {
    test('a brace inside one is part of its text', () {
      expect(
        readGame(_braceInside).tree!.children.single.comment,
        _braceInsideComment,
      );
    });

    test('are kept exactly, padding and all', () {
      expect(
        readGame('1. e4 { spaced out } *').tree!.children.single.comment,
        ' spaced out ',
      );
    });

    test('two in a row become one', () {
      expect(
        readGame('1. e4 {first} {second} *').tree!.children.single.comment,
        'first second',
      );
    });

    test('a comment holding a blank line does not cut the game short', () {
      final read = readGame(_runsOn);
      expect(mainlineSans(read.tree!), ['e4', 'd5', 'c4']);
    });
  });

  group('where a comment belongs', () {
    test('one written before a move stays before it', () {
      final read = readGame('1. e4 ({A note} 1. d4 d5) e5 *');
      final [e4, d4] = read.tree!.children;
      expect(e4.startingComment, isNull);
      expect(d4.startingComment, 'A note');
    });

    test('one before the first move is the game introduction', () {
      expect(
        readGame('{Why we play this} 1. e4 *').tree!.rootComment,
        'Why we play this',
      );
    });

    test('a semicolon comment runs to the end of its line', () {
      final read = readGame('1. e4 ; a thought\n e5 *');
      expect(read.tree!.children.single.comment, ' a thought');
      expect(mainlineSans(read.tree!), ['e4', 'e5']);
    });

    test('a semicolon inside braces is text', () {
      expect(
        readGame('1. e4 {a; b} e5 *').tree!.children.single.comment,
        'a; b',
      );
    });

    test('machine tokens are kept as written', () {
      final read = readGame(
        '1. e4 {[%eval 0.21] [%clk 0:29:41] [%emt 0:02]} '
        '{[%cal Ge2e4] [%csl Re4] [%score 46.4%]} *',
      );
      expect(
        read.tree!.children.single.comment,
        '[%eval 0.21] [%clk 0:29:41] [%emt 0:02] '
        '[%cal Ge2e4] [%csl Re4] [%score 46.4%]',
      );
    });

    test('a brace that never closes is reported', () {
      final read = readGame(_neverClosed);
      expect(read.tree!.children.single.comment, 'never ends');
      expect(read.issues.single, isA<UnterminatedComment>());
      expect(read.rewritable, isFalse);
    });
  });

  group('annotations', () {
    test('read numerically and symbolically the same way', () {
      expect(readGame(r'1. e4 $5 *').tree!.children.single.nags, [5]);
      expect(readGame('1. e4!? *').tree!.children.single.nags, [5]);
      expect(readGame('1. e4?! e5!! 2. Nf3?? *').tree!.children.single.nags, [
        6,
      ]);
    });

    test('several on one move keep their order', () {
      expect(readGame(r'1. e4 $1 $14 $146 *').tree!.children.single.nags, [
        1,
        14,
        146,
      ]);
    });

    test('one with no move is reported', () {
      final read = readGame(r'$1 1. e4 *');
      expect(read.issues.single, isA<StrayAnnotation>());
    });
  });
}
