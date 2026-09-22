import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_text.dart';

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

    test('strips semicolon rest-of-line comments before first Event', () {
      // Real-world shape: chessgames.com collection downloads open with a
      // `;`-comment banner (PGN spec rest-of-line comments).
      const pgn = '''
; Alexander Alekhine's Best Games
; Compiled by KingG on chessgames.com
; 120 games
;
[Event "Game 1"]

1. e4 e5 *

[Event "Game 2"]

1. d4 d5 *
''';
      final games = splitPgnIntoGames(pgn);
      expect(games, hasLength(2));
      expect(games[0], startsWith('[Event "Game 1"]'));
      expect(games[0], isNot(contains('Compiled by')));
    });

    test('does not split on [EventDate headers', () {
      // `[EventDate` shares the `[Event` prefix; splitting there would cut
      // every chessgames.com-style game in two.
      const pgn = '''
[Event "Game 1"]
[EventDate "1907.??.??"]

1. e4 e5 *

[Event "Game 2"]
[EventDate "1908.??.??"]

1. d4 d5 *
''';
      final games = splitPgnIntoGames(pgn);
      expect(games, hasLength(2));
      expect(games[0], contains('[EventDate "1907.??.??"]'));
      expect(countPgnGames(pgn), 2);
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

  group('countPgnGamesFast', () {
    // The fast counter powers the list/picker screens; it must agree with the
    // authoritative [countPgnGames] on the shapes the app actually writes.
    const fixtures = <String, String>{
      'blank-separated':
          '[Event "G1"]\n1. e4 *\n\n[Event "G2"]\n1. d4 *\n\n[Event "G3"]\n1. c4 *\n',
      'back-to-back':
          '[Event "L1"]\n1. e4 *\n[Event "L2"]\n1. d4 *\n[Event "L3"]\n1. c4 *\n',
      'brace-preamble':
          '{Build stats}\n[Event "L1"]\n1. e4 *\n[Event "L2"]\n1. d4 *\n',
      'comment-preamble':
          '// My Repertoire\n// Color: White\n\n[Event "L1"]\n1. e4 *\n',
      'header-less': '1. e4 e5 2. Nf3 *\n',
      'empty': '',
      'blank-only': '\n\n  \n',
      'comment-only': '// just a note\n',
      'semicolon-preamble':
          '; Best games collection\n; 2 games\n;\n[Event "G1"]\n1. e4 *\n\n[Event "G2"]\n1. d4 *\n',
      'semicolon-only': '; just a note\n;\n',
    };

    // What each fixture should count, stated independently of the code.
    // `countPgnGames` only delegates to `countPgnGamesFast`, so comparing the
    // two asserts nothing at all; the authority the doc comment names is
    // `splitPgnIntoGames`, and that is what the count has to agree with.
    const expectedCounts = <String, int>{
      'blank-separated': 3,
      'back-to-back': 3,
      'brace-preamble': 2,
      'comment-preamble': 1,
      'header-less': 1,
      'empty': 0,
      'blank-only': 0,
      'comment-only': 0,
      'semicolon-preamble': 2,
      'semicolon-only': 0,
    };

    fixtures.forEach((name, pgn) {
      test('counts $name the way the splitter splits it', () {
        expect(
          countPgnGamesFast(pgn),
          expectedCounts[name],
          reason: 'games in $name',
        );
        expect(
          countPgnGamesFast(pgn),
          splitPgnIntoGames(pgn).length,
          reason: 'the picker count must match the Lines list for $name',
        );
      });
    });

    test('handles a leading BOM like countPgnGames', () {
      const pgn = '﻿[Event "G1"]\n1. e4 *\n\n[Event "G2"]\n1. d4 *';
      expect(countPgnGamesFast(pgn), 2);
      expect(countPgnGamesFast(pgn), splitPgnIntoGames(stripBom(pgn)).length);
    });

    test('an [Event inside a comment is not a game', () {
      // `[Event ` only starts a game at a line start; a study comment that
      // quotes a header must not inflate the count.
      const pgn = '[Event "G1"]\n\n1. e4 {quoting [Event "Other"] here} e5 *\n';
      expect(countPgnGamesFast(pgn), 1);
      expect(splitPgnIntoGames(pgn), hasLength(1));
    });

    test('an indented [Event still starts a game', () {
      const pgn = '[Event "G1"]\n1. e4 *\n  [Event "G2"]\n1. d4 *\n';
      expect(countPgnGamesFast(pgn), 2);
      expect(countPgnGamesFast(pgn), splitPgnIntoGames(pgn).length);
    });

    // The invariant `countPgnGames` documents ("Agrees with
    // [splitPgnIntoGames] … so the count matches repertoire import and the
    // Lines list"). It did not hold: the counter returned the number of
    // `[Event ` line starts and never added the header-less chunk the splitter
    // synthesises above the first one, so a file with a non-comment banner
    // counted one game short of the Lines list built from it.
    test(
      'a non-comment preamble is counted the way the splitter splits it',
      () {
        // A collection whose banner carries no `;` / `//` / `{` marker — and
        // any file that opens with bare movetext and then has `[Event `
        // games. The splitter wraps the preamble as a header-less game of its
        // own, so the count has to see two games, not one.
        const pgn = "Alekhine's best games\n[Event \"G1\"]\n\n1. e4 *\n";
        expect(splitPgnIntoGames(pgn), hasLength(2));
        expect(countPgnGames(pgn), splitPgnIntoGames(pgn).length);
      },
    );
  });

  group('lastGameStart', () {
    const twoGames = '[Event "G1"]\n\n1. e4 *\n\n[Event "G2"]\n\n1. d4 *\n';

    test('cuts on the same boundary the splitter cuts on', () {
      final start = lastGameStart(twoGames);
      expect(start, greaterThan(0));
      // `RepertoireAuthoring.extractLastGamePgn` relies on exactly this: the
      // tail from here, plus the newline the splitter terminates its last
      // chunk with, IS the last game.
      expect(
        '${twoGames.substring(start)}\n',
        splitPgnIntoGames(twoGames).last,
      );
    });

    test('a single game starts at 0', () {
      expect(lastGameStart('[Event "G1"]\n\n1. e4 *\n'), 0);
    });

    test('header-less move text has no game start', () {
      expect(lastGameStart('1. e4 e5 *\n'), -1);
      expect(lastGameStart(''), -1);
    });

    test('an [Event quoted inside a comment is not a boundary', () {
      const pgn = '[Event "G1"]\n\n1. e4 {see [Event "Other"]} e5 *\n';
      expect(lastGameStart(pgn), 0);
    });

    test('[EventDate does not start a game', () {
      const pgn = '[Event "G1"]\n[EventDate "1907.??.??"]\n\n1. e4 *\n';
      expect(lastGameStart(pgn), 0);
    });

    test('an indented [Event is cut at its line start, not at the bracket', () {
      const pgn = '[Event "G1"]\n1. e4 *\n  [Event "G2"]\n1. d4 *\n';
      expect(pgn.substring(lastGameStart(pgn)), startsWith('  [Event "G2"]'));
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

    test('finds the colour under a metadata banner', () {
      // The shape this app actually writes: the `// Color:` line is never
      // the first line of a generated repertoire.
      const content =
          '// Repertoire: Sicilian\n'
          '// Created 2025-01-01\n'
          '// Color: Black\n'
          '\n'
          '[Event "L1"]\n1. e4 c5 *\n';
      expect(extractRepertoireColor(content), 'black');
    });

    test('ignores a colour that is not white or black', () {
      expect(extractRepertoireColor('// Color: Purple\n[Event ""]'), isNull);
    });
  });

  group('splitPlayerNames', () {
    test('single name passes through trimmed', () {
      expect(splitPlayerNames('  Carlsen '), ['Carlsen']);
    });

    test('splits on ; and drops empties', () {
      expect(splitPlayerNames('Carlsen; DrNykterstein; ;'), [
        'Carlsen',
        'DrNykterstein',
      ]);
    });

    test('commas stay inside a single name', () {
      expect(splitPlayerNames('Carlsen, Magnus'), ['Carlsen, Magnus']);
    });

    test('empty input yields no names', () {
      expect(splitPlayerNames(''), isEmpty);
      expect(splitPlayerNames(' ; '), isEmpty);
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
