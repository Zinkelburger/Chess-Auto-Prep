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

  group('gameMatchesSequence', () {
    const pgn = '1. e4 e5 2. Nf3 Nc6 *';

    test('no groups matches every game', () {
      expect(gameMatchesSequence(pgn, const [], 4), isTrue);
    });

    test('a move the game never plays does not match', () {
      expect(
        gameMatchesSequence(pgn, [
          ['d4'],
        ], 4),
        isFalse,
      );
    });

    test('two groups match only when the gap between them allows it', () {
      // e4 … Nc6 are three plies apart, so gap 4 bridges them and gap 0
      // (groups must be adjacent) does not.
      expect(
        gameMatchesSequence(pgn, [
          ['e4'],
          ['Nc6'],
        ], 4),
        isTrue,
      );
      expect(
        gameMatchesSequence(pgn, [
          ['e4'],
          ['Nc6'],
        ], 0),
        isFalse,
      );
    });

    test('a group must match consecutively', () {
      expect(
        gameMatchesSequence(pgn, [
          ['e4', 'Nf3'],
        ], 4),
        isFalse,
        reason: 'e4 and Nf3 are not consecutive plies',
      );
      expect(
        gameMatchesSequence(pgn, [
          ['e4', 'e5'],
        ], 4),
        isTrue,
      );
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

    test('a repeated position answers with its first continuation', () {
      // 1.Nf3 Nf6 2.Ng1 Ng8 returns to the starting position. The walk has to
      // stop at the first time the target is reached, or a shuffle at the
      // start of a game silently truncates the line the reader is shown.
      const pgn = '1. Nf3 Nf6 2. Ng1 Ng8 3. e4 *';
      expect(mainlineSansAfterFen(const {}, pgn, startFen), [
        'Nf3',
        'Nf6',
        'Ng1',
        'Ng8',
        'e4',
      ]);
    });

    test('a position the game never reaches yields nothing', () {
      Position pos = Chess.initial;
      for (final san in ['d4', 'd5']) {
        pos = pos.play(pos.parseSan(san)!);
      }
      const pgn = '1. e4 e5 2. Nf3 *';
      expect(
        mainlineSansAfterFen(const {}, pgn, normalizeFen(pos.fen)),
        isEmpty,
      );
      expect(
        gamePassesThroughFen(const {}, pgn, normalizeFen(pos.fen)),
        isFalse,
        reason: 'the game never plays 1.d4',
      );
      expect(
        gamePassesThroughFen(const {}, pgn, normalizeFen(Chess.initial.fen)),
        isTrue,
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

  group('computeSliceMatches - filter modes', () {
    List<GameRecord> games() => [
      (
        headers: {'White': 'Carlsen', 'WhiteElo': '2850'},
        pgnText: '[Event "a"]\n\n1. e4 e5 2. Nf3 Nc6 *',
      ),
      (
        headers: {'White': 'Nakamura', 'WhiteElo': '2780'},
        pgnText: '[Event "b"]\n\n1. e4 e5 2. Bc4 Nf6 *',
      ),
    ];

    Future<List<int>> matching(
      MatchMode mode,
      String value, {
      String field = 'White',
    }) => computeSliceMatches(
      games: games(),
      filters: [(field: field, mode: mode, value: value)],
      seqGroups: const [],
      seqGap: 4,
    );

    // The slice runs in an isolate through _CompiledFilter, which re-implements
    // every mode that [matchesField] implements. These assert the compiled
    // copy, so the two cannot drift apart unnoticed.
    test('exact matches the whole value, case-insensitively', () async {
      expect(await matching(MatchMode.exact, 'carlsen'), [0]);
      expect(
        await matching(MatchMode.exact, 'carls'),
        isEmpty,
        reason: 'exact is not a prefix match',
      );
    });

    test('contains and notContains partition the games', () async {
      expect(await matching(MatchMode.contains, 'carls'), [0]);
      expect(await matching(MatchMode.notContains, 'carls'), [1]);
    });

    test('regex filters, and an unparsable pattern matches nothing', () async {
      expect(await matching(MatchMode.regex, r'^Naka'), [1]);
      expect(await matching(MatchMode.regex, r'^(unclosed'), isEmpty);
    });

    test('after/before compare ratings numerically', () async {
      expect(await matching(MatchMode.after, '2800', field: 'WhiteElo'), [0]);
      expect(await matching(MatchMode.before, '2800', field: 'WhiteElo'), [1]);
    });

    test('a sequence filter excludes the games that do not play it', () async {
      final matched = await computeSliceMatches(
        games: games(),
        filters: const [],
        seqGroups: [
          ['Nf3'],
        ],
        seqGap: 4,
      );
      expect(matched, [0]);
    });

    test('the indexed fast path still applies the sequence filter', () async {
      // With a `.fenidx` on disk the position lookup short-circuits; the
      // other filters must still run over the candidates it returns.
      final all = games();
      final index = buildFenIndex(all);
      Position pos = Chess.initial;
      for (final san in ['e4', 'e5']) {
        pos = pos.play(pos.parseSan(san)!);
      }
      final afterE5 = normalizeFen(pos.fen);
      expect(index[afterE5], [0, 1]);

      expect(
        await computeSliceMatches(
          games: all,
          targetFen: afterE5,
          filters: const [],
          seqGroups: const [],
          seqGap: 4,
          fenIndex: index,
        ),
        [0, 1],
      );
      expect(
        await computeSliceMatches(
          games: all,
          targetFen: afterE5,
          filters: const [],
          seqGroups: [
            ['Nf3'],
          ],
          seqGap: 4,
          fenIndex: index,
        ),
        [0],
      );
      expect(
        await computeSliceMatches(
          games: all,
          targetFen: afterE5,
          filters: [(field: 'White', mode: MatchMode.contains, value: 'naka')],
          seqGroups: const [],
          seqGap: 4,
          fenIndex: index,
        ),
        [1],
      );
    });
  });

  group('FEN index round trip', () {
    const gameCount = 2;
    const fileSize = 1234;
    const modifiedMs = 99999;

    String blobOf(Map<String, List<int>> index) => serializeFenIndex(
      index,
      gameCount: gameCount,
      fileSize: fileSize,
      modifiedMs: modifiedMs,
    );

    Map<String, List<int>>? readBack(String blob) => deserializeFenIndex(
      blob,
      expectedGameCount: gameCount,
      expectedFileSize: fileSize,
      expectedModifiedMs: modifiedMs,
    );

    test('a serialized index reads back unchanged', () {
      final index = {
        'a/fen w - -': [0, 1],
        'b/fen b - -': [1],
      };
      expect(readBack(blobOf(index)), index);
    });

    test('a header we did not write forces a rebuild', () {
      final good = blobOf({
        'a/fen w - -': [0],
      });
      const header = 'FENIDX3 $gameCount $fileSize $modifiedMs';
      expect(readBack(good), isNotNull);
      expect(readBack(good.replaceFirst('FENIDX3', 'FENIDX2')), isNull);
      expect(
        readBack(good.replaceFirst(header, '$header 99')),
        isNull,
        reason: 'an extra header field is not a format we can trust',
      );
      expect(
        readBack(good.replaceFirst(header, 'FENIDX3 $gameCount $fileSize')),
        isNull,
        reason: 'a truncated header is not a format we can trust',
      );
    });
  });
}
