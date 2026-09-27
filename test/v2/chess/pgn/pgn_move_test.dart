import 'package:chess_auto_prep/v2/chess/pgn/pgn_issue.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('moves', () {
    test('keep the spelling the file used', () {
      final castle = readGame(
        '[FEN "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"]\n\n1. 0-0 0-0-0 *',
      );
      final [white] = castle.tree!.children;
      expect(white.san, 'O-O');
      expect(white.spelling, '0-0');
      expect(white.children.single.spelling, '0-0-0');
    });

    test('an over-precise disambiguation is kept', () {
      final read = readGame('1. e4 e5 2. Ngf3 *');
      final node = read.tree!.children.single.children.single.children.single;
      expect(node.san, 'Nf3');
      expect(node.spelling, 'Ngf3');
    });

    test('a promotion is read with or without the equals sign', () {
      for (final san in const ['e8=Q', 'e8Q', 'e8=q']) {
        final read = readGame(
          '[FEN "8/4P3/8/8/8/8/8/K6k w - - 0 1"]\n\n1. '
          '$san *',
        );
        expect(read.tree!.children.single.san, 'e8=Q', reason: san);
        expect(read.issues, isEmpty, reason: san);
      }
    });

    test('a check or mate suffix is part of the spelling', () {
      final read = readGame('1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7# *');
      expect(mainlineSans(read.tree!).last, 'Qxf7#');
    });

    test('en passant written out is ignored', () {
      final read = readGame('1. e4 d5 2. e5 f5 3. exf6 e.p. *');
      expect(mainlineSans(read.tree!), ['e4', 'd5', 'e5', 'f5', 'exf6']);
      expect(read.issues, isEmpty);
    });
  });

  group('a ply where nobody moved', () {
    test('is a move of its own', () {
      final read = readGame('{An introduction} 1. -- *');
      final node = read.tree!.children.single;
      expect(node.san, '--');
      expect(node.uci, '0000');
      expect(node.fen.whiteToMove, isFalse);
      expect(read.issues, isEmpty);
    });

    test('is spelled Z0 and @@@@ too, and keeps its spelling', () {
      for (final spelling in const ['Z0', '@@@@', '0000']) {
        final read = readGame('1. $spelling *');
        expect(read.tree!.children.single.san, '--', reason: spelling);
        expect(read.tree!.children.single.spelling, spelling, reason: spelling);
      }
    });

    test('carries the variations under it', () {
      final read = readGame('1. Z0 (1. d4 d5) e5 *');
      final [waiting, d4] = read.tree!.children;
      expect(waiting.san, '--');
      expect(waiting.children.single.san, 'e5');
      expect(d4.san, 'd4');
      expect(read.issues, isEmpty);
    });

    test('does not make the move after it White\'s again', () {
      final read = readGame('1. e4 e5 2. Ke3 *');
      expect(mainlineSans(read.tree!), ['e4', 'e5']);
      expect(read.issues.first, isA<IllegalMove>());
      expect(read.issues.first.line, 1);
      expect(read.issues.first.column, 13);
      expect(read.rewritable, isFalse);
    });
  });

  group('variations', () {
    test('nest as deep as the file nests them', () {
      final read = readGame('1. e4 (1. d4 (1. c4 (1. Nf3 (1. g3))) ) e5 *');
      expect(read.tree!.children.map((n) => n.san), [
        'e4',
        'd4',
        'c4',
        'Nf3',
        'g3',
      ]);
      expect(read.issues, isEmpty);
    });

    test('an empty one is reported', () {
      final read = readGame('1. e4 () e5 *');
      expect(read.issues.single, isA<EmptyVariation>());
      expect(read.rewritable, isFalse);
    });

    test('one that never closes is reported', () {
      final read = readGame('1. e4 (1. d4 e5');
      expect(read.issues.single, isA<UnterminatedVariation>());
      expect(read.rewritable, isFalse);
    });

    test('a bracket that closes nothing is reported', () {
      expect(readGame('1. e4) e5 *').issues.single, isA<StrayVariationEnd>());
    });
  });
}
