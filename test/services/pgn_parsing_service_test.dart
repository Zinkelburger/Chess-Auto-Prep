import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';

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

    fixtures.forEach((name, pgn) {
      test('matches countPgnGames for $name', () {
        expect(countPgnGamesFast(pgn), countPgnGames(pgn));
      });
    });

    test('handles a leading BOM like countPgnGames', () {
      const pgn = '﻿[Event "G1"]\n1. e4 *\n\n[Event "G2"]\n1. d4 *';
      expect(countPgnGamesFast(pgn), countPgnGames(pgn));
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

  group('playerFieldMatches', () {
    test('contains matches either colour, any alias', () {
      expect(
        playerFieldMatches(
          'Carlsen, Magnus',
          'Nakamura, Hikaru',
          'carlsen',
          MatchMode.contains,
        ),
        isTrue,
      );
      expect(
        playerFieldMatches(
          'Nakamura, Hikaru',
          'Carlsen,M',
          'carlsen; ding',
          MatchMode.contains,
        ),
        isTrue,
      );
      expect(
        playerFieldMatches(
          'Nakamura, Hikaru',
          'So, Wesley',
          'carlsen',
          MatchMode.contains,
        ),
        isFalse,
      );
    });

    test('notContains requires every alias absent from both sides', () {
      expect(
        playerFieldMatches(
          'Nakamura, Hikaru',
          'So, Wesley',
          'carlsen',
          MatchMode.notContains,
        ),
        isTrue,
      );
      expect(
        playerFieldMatches(
          'Carlsen, Magnus',
          'So, Wesley',
          'carlsen; nakamura',
          MatchMode.notContains,
        ),
        isFalse,
      );
    });

    test('empty query matches everything', () {
      expect(playerFieldMatches('A', 'B', '', MatchMode.contains), isTrue);
    });
  });

  group('computeSliceMatches - Player field', () {
    List<GameRecord> games() => [
      (
        headers: {'White': 'Carlsen, Magnus', 'Black': 'Nakamura, Hikaru'},
        pgnText: '1. e4 e5 *',
      ),
      (
        headers: {'White': 'Caruana, Fabiano', 'Black': 'Carlsen,M'},
        pgnText: '1. d4 d5 *',
      ),
      (
        headers: {'White': 'Ding, Liren', 'Black': 'So, Wesley'},
        pgnText: '1. c4 e5 *',
      ),
    ];

    test('matches either colour with aliases', () async {
      final indices = await computeSliceMatches(
        games: games(),
        filters: [
          (
            field: kPlayerHeaderField,
            mode: MatchMode.contains,
            value: 'carlsen; ding',
          ),
        ],
        seqGroups: const [],
        seqGap: 4,
      );
      expect(indices, [0, 1, 2]);
    });

    test('excludes games matching no alias', () async {
      final indices = await computeSliceMatches(
        games: games(),
        filters: [
          (
            field: kPlayerHeaderField,
            mode: MatchMode.contains,
            value: 'carlsen',
          ),
        ],
        seqGroups: const [],
        seqGap: 4,
      );
      expect(indices, [0, 1]);
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

  group('mainlineSansAfterFen', () {
    const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

    String fenAfter(List<String> sans) {
      Position pos = Chess.initial;
      for (final san in sans) {
        final move = pos.parseSan(san);
        if (move == null) {
          throw StateError('illegal SAN $san');
        }
        pos = pos.play(move);
      }
      return pos.fen;
    }

    test('returns the full mainline from the starting position', () {
      expect(
        mainlineSansAfterFen(const {}, '1. e4 e5 2. Nf3 Nc6 *', startFen),
        ['e4', 'e5', 'Nf3', 'Nc6'],
      );
    });

    test('returns remaining SAN after a mid-game FEN, without comments', () {
      const pgn = '1. e4 {best} e5 {reply} 2. Nf3 (2. d4) Nc6 *';
      expect(mainlineSansAfterFen(const {}, pgn, fenAfter(['e4'])), [
        'e5',
        'Nf3',
        'Nc6',
      ]);
    });

    test('returns empty when the FEN is never reached', () {
      expect(
        mainlineSansAfterFen(const {}, '1. e4 e5 *', 'not-a-fen'),
        isEmpty,
      );
    });

    test('caps remaining plies', () {
      expect(
        mainlineSansAfterFen(
          const {},
          '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *',
          startFen,
          maxPlies: 3,
        ),
        ['e4', 'e5', 'Nf3'],
      );
    });
  });

  group('ChessBase / Chessable null moves (Z0 / --)', () {
    const colle = '1. d4 Z0 2. Nf3 Z0 3. e3 *';

    String fenAfter(List<String> sans) {
      Position pos = Chess.initial;
      for (final san in sans) {
        pos = playSanOrNullMove(pos, san)!;
      }
      return pos.fen;
    }

    test('parseTargetFen replays Z0 as a pass', () {
      final fen = parseTargetFen('d4 Z0 Nf3');
      expect(fen, normalizeFen(fenAfter(['d4', '--', 'Nf3'])));
    });

    test('gamePassesThroughFen reaches positions after a Z0 pass', () {
      expect(
        gamePassesThroughFen(const {}, colle, normalizeFen(fenAfter(['d4']))),
        isTrue,
      );
      expect(
        gamePassesThroughFen(
          const {},
          colle,
          normalizeFen(fenAfter(['d4', '--', 'Nf3'])),
        ),
        isTrue,
      );
    });

    test('buildFenIndex records positions after null-move passes', () {
      final index = buildFenIndex([(headers: const {}, pgnText: colle)]);
      expect(index[normalizeFen(fenAfter(['d4', '--', 'Nf3']))], [0]);
    });

    test('mainlineSansAfterFen keeps going past Z0', () {
      expect(mainlineSansAfterFen(const {}, colle, Chess.initial.fen), [
        'd4',
        '--',
        'Nf3',
        '--',
        'e3',
      ]);
    });

    test('gameMatchesSequence ignores Z0 tokens in the mainline', () {
      expect(
        gameMatchesSequence(colle, [
          ['d4', 'Nf3', 'e3'],
        ], 4),
        isTrue,
      );
    });

    test('gamePassesThroughFen finds a position that lives only in a RAV', () {
      const pgn = '1. e4 e5 (1... c5 2. Nf3) 2. Nf3 *';
      final afterC5 = normalizeFen(fenAfter(['e4', 'c5']));
      expect(gamePassesThroughFen(const {}, pgn, afterC5), isTrue);
      expect(buildFenIndex([(headers: const {}, pgnText: pgn)])[afterC5], [0]);
      expect(mainlineSansAfterFen(const {}, pgn, afterC5), ['Nf3']);
    });

    test('promoted Chessable intro is indexed on the lesson moves', () {
      const intro =
          '1. Z0 ({Welcome} 1. d4 {We intend to play} Z0 2. Nf3 {and} '
          'Z0 3. e3 {next.}) *';
      final afterD4 = normalizeFen(fenAfter(['d4']));
      expect(gamePassesThroughFen(const {}, intro, afterD4), isTrue);
      expect(mainlineSansAfterFen(const {}, intro, Chess.initial.fen), [
        'd4',
        '--',
        'Nf3',
        '--',
        'e3',
      ]);
    });
  });
}
