/// The header block and mainline lexer: what it reads off game text must be
/// exactly what dartchess parses (see also `mainline_lexer_test.dart`).
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/services/pgn_mainline_lexer.dart';

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
      // What `PgnViewerController.persistMoveCommentsFor` does on every save.
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
  });
}
