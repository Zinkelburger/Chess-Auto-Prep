import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/core/pgn/pgn_collection_helpers.dart';

void main() {
  group('pgnCollectionPreamble', () {
    // The banner [parseMultiGamePgn] deliberately drops has to be kept
    // somewhere: a save rewrites the whole file from the games alone, so
    // without this the reader's own header text was deleted by a star.
    test('returns the banner above the first game', () {
      const pgn =
          "; Alexander Alekhine's Best Games\n"
          '; Compiled by KingG on chessgames.com\n'
          '\n'
          '[Event "Game 1"]\n'
          '[White "Alexander Alekhine"]\n'
          '\n'
          '1. e4 e5 *\n';
      expect(
        pgnCollectionPreamble(pgn),
        "; Alexander Alekhine's Best Games\n"
        '; Compiled by KingG on chessgames.com',
      );
    });

    test('a file that opens on a game has no preamble', () {
      const pgn = '[Event "Game 1"]\n\n1. e4 e5 *\n';
      expect(pgnCollectionPreamble(pgn), '');
    });

    test('movetext above the first header is a game, not a preamble', () {
      // `parseMultiGamePgn` gives that text a synthetic header block and
      // returns it as a game, so claiming it here would write it into the
      // file twice.
      const pgn = '1. e4 e5 *\n\n[Event "Game 1"]\n\n1. d4 d5 *\n';
      expect(pgnCollectionPreamble(pgn), '');
    });
  });

  group('parseMultiGamePgn', () {
    test('parses blank-line-separated games', () {
      const pgn = '''
[Event "Game 1"]
[White "Alice"]

1. e4 e5 *

[Event "Game 2"]
[White "Carol"]

1. d4 d5 *
''';
      final entries = parseMultiGamePgn(pgn);
      expect(entries, hasLength(2));
      expect(entries[0].headers['Event'], 'Game 1');
      expect(entries[1].headers['Event'], 'Game 2');
    });

    test('skips a semicolon-comment banner before the first game', () {
      // Real-world shape: chessgames.com collection downloads open with a
      // `;`-comment banner (PGN spec rest-of-line comments). It must not
      // surface as a blank extra game.
      const pgn = '''
; Alexander Alekhine's Best Games
; Compiled by KingG on chessgames.com
; 120 games
;
[Event "Game 1"]
[White "Alexander Alekhine"]

1. e4 e5 *

[Event "Game 2"]
[White "Alexander Alekhine"]

1. d4 d5 *
''';
      final entries = parseMultiGamePgn(pgn);
      expect(entries, hasLength(2));
      expect(entries[0].headers['Event'], 'Game 1');
    });

    test('skips // and % preamble lines too', () {
      const pgn = '''
// Color: White
% escape line
[Event "Only Game"]

1. e4 *
''';
      final entries = parseMultiGamePgn(pgn);
      expect(entries, hasLength(1));
      expect(entries[0].headers['Event'], 'Only Game');
    });

    test('does not split on [EventDate headers', () {
      const pgn = '''
[Event "Game 1"]
[EventDate "1907.??.??"]

1. e4 e5 *
''';
      final entries = parseMultiGamePgn(pgn);
      expect(entries, hasLength(1));
      expect(entries[0].headers['EventDate'], '1907.??.??');
    });
  });
}
