/// The header block and mainline lexer: what it reads off game text must be
/// exactly what dartchess parses (see also `mainline_lexer_test.dart`).
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/chess_core/pgn/mainline_lexer.dart';

void main() {
  group('extractHeaderBlock', () {
    test('reads only the leading header block, decoding escapes', () {
      const pgn =
          '[Event "A \\"quoted\\" name"]\n'
          '[Site "x\\\\y"]\n'
          '\n'
          '1. e4 {[Event "inside a comment"]} e5 *\n';
      final headers = extractHeaderBlock(pgn);
      expect(headers, {'Event': 'A "quoted" name', 'Site': 'x\\y'});
    });

    test('is empty for header-less movetext', () {
      expect(extractHeaderBlock('1. e4 e5 *'), isEmpty);
    });

    test('stops at a % escape line after the headers', () {
      expect(extractHeaderBlock('[Event "G"]\n%stop\n[Site "S"]\n'), {
        'Event': 'G',
      });
    });
  });

  group('movetextStart', () {
    test('splits a game into all of its headers and all of its moves', () {
      const pgn = '[Event "G"]\n[White "A"]\n\n1. e4 e5 2. Nf3 *\n';
      final cut = movetextStart(pgn);
      expect(
        extractHeaderBlock(pgn.substring(0, cut)),
        extractHeaderBlock(pgn),
      );
      expect(mainlineSansOf(pgn.substring(cut)), ['e4', 'e5', 'Nf3']);
    });

    test('header-less move text starts at 0', () {
      expect(movetextStart('1. e4 e5 *'), 0);
    });

    test('moves sharing the last header line start after the tag', () {
      const pgn = '[Event "G"] 1. e4 *';
      expect(pgn.substring(movetextStart(pgn)).trim(), '1. e4 *');
    });

    test('a comment line that ends in ] does not move the boundary', () {
      // The heuristic this replaced cut after the last `]`-terminated line,
      // which lands in the middle of a wrapped `{[%eval ...]}` comment.
      const pgn = '[Event "G"]\n\n1. e4 {[%eval 0.17]\n[%clk 0:03:00]} e5 *\n';
      expect(pgn.substring(movetextStart(pgn)), startsWith('1. e4'));
      expect(mainlineSansOf(pgn), ['e4', 'e5']);
    });

    test('a game with no movetext points past the end', () {
      const pgn = '[Event "G"]\n';
      expect(movetextStart(pgn), greaterThan(pgn.length));
    });

    test('the header side rejoins new movetext into a readable game', () {
      // What `ViewerDocumentController.persistMoveCommentsFor` does on every save.
      const pgn = '[Event "G"]\n[Site "S"]\n\n1. d4 d5 *\n';
      final headerPart = pgn.substring(0, movetextStart(pgn)).trimRight();
      final rebuilt = '$headerPart\n\n1. d4 Nf6 *\n';
      expect(extractHeaderBlock(rebuilt), extractHeaderBlock(pgn));
      expect(mainlineSansOf(rebuilt), ['d4', 'Nf6']);
    });
  });

  group('mainlineSansOf', () {
    List<String> viaDartchess(String pgn) =>
        PgnGame.parsePgn(pgn).moves.mainline().map((n) => n.san).toList();

    test('nothing inside a same-line brace comment is lexed', () {
      // The comment's last character is a `;`, which outside a comment ends
      // the line: read it and the rest of the mainline disappears.
      const pgn = '[Event "G"]\n\n1. e4 {sharp; see below;} e5 2. Nf3 *\n';
      expect(mainlineSansOf(pgn), ['e4', 'e5', 'Nf3']);
      expect(mainlineSansOf(pgn), viaDartchess(pgn));
    });

    test('a comment ending in a variation bracket is still just a comment', () {
      const pgn = '[Event "G"]\n\n1. e4 {compare (} e5 2. Nf3 *\n';
      expect(mainlineSansOf(pgn), ['e4', 'e5', 'Nf3']);
      expect(mainlineSansOf(pgn), viaDartchess(pgn));
    });

    test('variations are not mainline moves', () {
      const pgn = '[Event "G"]\n\n1. e4 (1. d4 d5) e5 *\n';
      expect(mainlineSansOf(pgn), ['e4', 'e5']);
      expect(mainlineSansOf(pgn), viaDartchess(pgn));
    });

    // The Games feature used to lex downloaded games with a regex of its
    // own; these are the shapes that extractor was written for.
    test('plain movetext with numbers and result', () {
      expect(mainlineSansOf('[Event "x"]\n\n1. e4 e5 2. Nf3 Nc6 1-0'), [
        'e4',
        'e5',
        'Nf3',
        'Nc6',
      ]);
    });

    test('strips clock/eval comments and NAGs', () {
      const pgn =
          '1. e4 { [%clk 0:03:00] } 1... c5 { [%eval 0.3] } 2. Nf3 \$2 d6 *';
      expect(mainlineSansOf(pgn), ['e4', 'c5', 'Nf3', 'd6']);
      expect(mainlineSansOf(pgn), viaDartchess(pgn));
    });

    test('skips nested variations entirely', () {
      const pgn = '1. d4 d5 (1... Nf6 2. c4 (2. Bg5)) 2. c4 e6 *';
      expect(mainlineSansOf(pgn), ['d4', 'd5', 'c4', 'e6']);
      expect(mainlineSansOf(pgn), viaDartchess(pgn));
    });

    test('handles glued move numbers and black continuations', () {
      expect(mainlineSansOf('1.e4 e5 2.Nf3 2...Nc6 *'), [
        'e4',
        'e5',
        'Nf3',
        'Nc6',
      ]);
    });

    test('keeps check and mate suffixes on the SAN', () {
      expect(mainlineSansOf('1. e4 f6 2. Qh5+ g6 3. Qxg6#'), [
        'e4',
        'f6',
        'Qh5+',
        'g6',
        'Qxg6#',
      ]);
    });

    test('the batch form lexes each game independently', () {
      expect(mainlineSansOfBatch(['1. e4 e5 *', '1. d4 *', '']), [
        ['e4', 'e5'],
        ['d4'],
        <String>[],
      ]);
    });
  });
}
