import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_issue.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/pgn_round_trip.dart';

List<String> sansOf(GameTree tree) {
  final sans = <String>[];
  var siblings = tree.children;
  while (siblings.isNotEmpty) {
    sans.add(siblings.first.san);
    siblings = siblings.first.children;
  }
  return sans;
}

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
        expect(sansOf(readGame(game).tree!), ['e4', 'e5', 'Nf3'], reason: game);
      }
    });

    test('do not say whose move it is', () {
      // A course that numbers Black's ply with a single dot, which is the
      // commonest repertoire export on this machine.
      final read = readGame('1. e4\n1. e5\n2. Nf3\n2. Nc6\n*');
      expect(sansOf(read.tree!), ['e4', 'e5', 'Nf3', 'Nc6']);
      expect(read.issues, isEmpty);
    });

    test('a five-digit number is a number, not a null move', () {
      // `0000` spells a ply where nobody moved, so a reader that looks for
      // words before numbers turns move ten thousand into one.
      final read = readGame('10000. e4 10000... e5 *');
      expect(sansOf(read.tree!), ['e4', 'e5']);
      expect(read.issues, isEmpty);
    });
  });

  group('comments', () {
    test('a brace inside one is part of its text', () {
      expect(
        readGame('1. e4 {see {this} *').tree!.children.single.comment,
        'see {this',
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
      final read = readGame('''
[Event "Notes"]
[Result "*"]

1. e4 {A thought that runs on

[%eval 0.21]} d5 2. c4 *
''');
      expect(sansOf(read.tree!), ['e4', 'd5', 'c4']);
    });

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
      expect(sansOf(read.tree!), ['e4', 'e5']);
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
      final read = readGame('1. e4 {never ends');
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
      expect(sansOf(read.tree!).last, 'Qxf7#');
    });

    test('en passant written out is ignored', () {
      final read = readGame('1. e4 d5 2. e5 f5 3. exf6 e.p. *');
      expect(sansOf(read.tree!), ['e4', 'd5', 'e5', 'f5', 'exf6']);
      expect(read.issues, isEmpty);
    });

    test('a ply where nobody moved is a move of its own', () {
      final read = readGame('{An introduction} 1. -- *');
      final node = read.tree!.children.single;
      expect(node.san, '--');
      expect(node.uci, '0000');
      expect(node.fen.whiteToMove, isFalse);
      expect(read.issues, isEmpty);
    });

    test('Z0 and @@@@ mean the same and keep their spelling', () {
      for (final spelling in const ['Z0', '@@@@', '0000']) {
        final read = readGame('1. $spelling *');
        expect(read.tree!.children.single.san, '--', reason: spelling);
        expect(read.tree!.children.single.spelling, spelling, reason: spelling);
      }
    });

    test('a waiting ply carries the variations under it', () {
      final read = readGame('1. Z0 (1. d4 d5) e5 *');
      final [waiting, d4] = read.tree!.children;
      expect(waiting.san, '--');
      expect(waiting.children.single.san, 'e5');
      expect(d4.san, 'd4');
      expect(read.issues, isEmpty);
    });

    test('an illegal move ends its branch and is reported', () {
      final read = readGame('1. e4 e5 2. Ke3 *');
      expect(sansOf(read.tree!), ['e4', 'e5']);
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

  group('the game termination marker', () {
    test('is read as the file wrote it', () {
      for (final marker in const ['1-0', '0-1', '1/2-1/2', '*']) {
        expect(readGame('1. e4 $marker').terminator, marker, reason: marker);
      }
    });

    test('is not the Result tag, and neither replaces the other', () {
      final read = readGame('[Result "*"]\n\n1. e4 1-0');
      expect(read.terminator, '1-0');
      expect(tagValue(read.tags, 'Result'), '*');
      expectExactRoundTrip('[Result "*"]\n\n1. e4 1-0');
    });

    test('a game with none keeps having none', () {
      final read = readGame('[Event "A"]\n\n1. e4 e5');
      expect(read.terminator, isNull);
      expectExactRoundTrip('[Event "A"]\n\n1. e4 e5');
    });

    test('a game with no Result tag keeps its marker', () {
      expectExactRoundTrip('[Event "A"]\n\n1. e4 1-0');
    });

    test('a second one is reported', () {
      expect(readGame('1. e4 * 1-0').issues.last, isA<ExtraTermination>());
    });

    test('moves after it are reported', () {
      final read = readGame('1. e4 * e5');
      expect(read.issues.single, isA<MovesAfterTermination>());
    });
  });

  group('text nothing can read', () {
    test('an unusable FEN leaves the game unread', () {
      final read = readGame('[FEN "not a fen"]\n\n1. e4 *');
      expect(read.tree, isNull);
      expect(read.issues.single, isA<UnreadablePosition>());
    });

    test('a word that is not a move is reported where it stands', () {
      final read = readGame('[Event "A"]\n\n1. e4 zzz e5 *');
      final issue = read.issues.single;
      expect(issue, isA<UnknownToken>());
      expect(issue.line, 3);
      expect(issue.column, 7);
    });

    test('a percent escape among the moves is reported', () {
      final read = readGame('[Event "A"]\n\n1. e4\n%a directive\ne5 *');
      expect(read.issues.single, isA<EscapeInMovetext>());
    });

    test('a percent escape in the header is a header line', () {
      final read = readGame(
        '[Event "A"]\n%a directive\n[Result "*"]\n\n1. e4 *',
      );
      expect(read.tags.map((t) => t.text), [
        '[Event "A"]',
        '%a directive',
        '[Result "*"]',
      ]);
      expect(read.issues, isEmpty);
    });

    test('nothing throws, whatever the text is', () {
      for (final text in const [
        '',
        '   ',
        '{',
        '}',
        '(',
        ')',
        r'$',
        '[',
        '[Event',
        '[Event "',
        '1.',
        '1. e4 ({[( e5 *',
        r'$1 $2 $255',
        '*',
        '1-0',
        'Zz9',
        '1. e4 \u{1F600} *',
      ]) {
        expect(() => readGame(text), returnsNormally, reason: '"$text"');
      }
    });
  });
}
