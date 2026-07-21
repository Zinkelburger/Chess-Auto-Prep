import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/core/pgn/pgn_collection_helpers.dart';

void main() {
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
