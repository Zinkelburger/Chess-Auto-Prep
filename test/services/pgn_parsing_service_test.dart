import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';

void main() {
  group('splitPgnIntoGames', () {
    test('splits two standard games', () {
      const pgn = '''
[Event "Game 1"]
[White "Alice"]
[Black "Bob"]

1. e4 e5 *

[Event "Game 2"]
[White "Carol"]
[Black "Dave"]

1. d4 d5 *
''';
      final games = splitPgnIntoGames(pgn);
      expect(games, hasLength(2));
      expect(games[0], contains('[Event "Game 1"]'));
      expect(games[1], contains('[Event "Game 2"]'));
    });

    test('strips top-level comment lines', () {
      const pgn = '''
// Color: White
// Created 2025-01-01
[Event "Only Game"]

1. e4 *
''';
      final games = splitPgnIntoGames(pgn);
      expect(games, hasLength(1));
      expect(games[0], isNot(contains('// Color')));
    });

    test('strips top-level brace comment before first Event', () {
      const pgn = '''
{Build stats: 1 nodes}
[Event "Only Game"]
1. e4 *
''';
      final games = splitPgnIntoGames(pgn);
      expect(games, hasLength(1));
      expect(games[0], isNot(contains('Build stats')));
    });

    test('wraps bare movetext without headers', () {
      const pgn = '1. e4 e5 2. Nf3 *';
      final games = splitPgnIntoGames(pgn);
      expect(games, hasLength(1));
      expect(games[0], contains('[Event "Repertoire Line"]'));
      expect(games[0], contains('1. e4'));
    });

    test('returns empty for empty input', () {
      expect(splitPgnIntoGames(''), isEmpty);
      expect(splitPgnIntoGames('   \n\n  '), isEmpty);
    });

    test('splits games after stripping BOM', () {
      const pgn = '\uFEFF[Event "G1"]\n1. e4 *\n\n[Event "G2"]\n1. d4 *';
      final games = splitPgnIntoGames(stripBom(pgn));
      expect(games, hasLength(2));
    });
  });

  group('extractHeaders', () {
    test('extracts standard PGN headers', () {
      const pgn = '[Event "Test"]\n[White "Alice"]\n[Black "Bob"]\n\n1. e4 *';
      final headers = extractHeaders(pgn);
      expect(headers['Event'], 'Test');
      expect(headers['White'], 'Alice');
      expect(headers['Black'], 'Bob');
    });

    test('returns empty map for no headers', () {
      expect(extractHeaders('1. e4 e5 *'), isEmpty);
    });
  });

  group('countPgnGames', () {
    test('counts multiple games', () {
      const pgn = '''
[Event "G1"]
1. e4 *

[Event "G2"]
1. d4 *

[Event "G3"]
1. c4 *
''';
      expect(countPgnGames(pgn), 3);
    });

    test('returns 0 for empty input', () {
      expect(countPgnGames(''), 0);
    });

    test('counts games with leading BOM', () {
      const pgn = '\uFEFF[Event "G1"]\n1. e4 *\n\n[Event "G2"]\n1. d4 *';
      expect(countPgnGames(stripBom(pgn)), 2);
    });

    test('counts back-to-back [Event] games without blank lines', () {
      const pgn = '''
[Event "Line 1"]
1. e4 *
[Event "Line 2"]
1. d4 *
[Event "Line 3"]
1. c4 *
''';
      expect(countPgnGames(pgn), 3);
      expect(countPgnGames(pgn), splitPgnIntoGames(pgn).length);
    });

    test('ignores brace preamble before first Event', () {
      const pgn = '''
{Build stats: example}
[Event "Line 1"]
1. e4 *
[Event "Line 2"]
1. d4 *
''';
      expect(countPgnGames(pgn), 2);
      expect(splitPgnIntoGames(pgn), hasLength(2));
    });
  });

  group('extractRepertoireColor', () {
    test('finds White', () {
      expect(extractRepertoireColor('// Color: White\n[Event ""]'), 'white');
    });

    test('finds Black', () {
      expect(extractRepertoireColor('// Color: Black\n[Event ""]'), 'black');
    });

    test('returns null when absent', () {
      expect(extractRepertoireColor('[Event "Test"]\n1. e4 *'), isNull);
    });

    test('stops before first Event header', () {
      const content = '[Event "Test"]\n// Color: White\n1. e4 *';
      expect(extractRepertoireColor(content), isNull);
    });
  });

  group('stripBom', () {
    test('removes UTF-8 BOM', () {
      expect(stripBom('\uFEFFhello'), 'hello');
    });

    test('passes through clean strings', () {
      expect(stripBom('hello'), 'hello');
    });
  });
}
