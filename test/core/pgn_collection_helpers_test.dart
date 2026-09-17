import 'package:chess_auto_prep/features/documents/models/viewer_filter_actions.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_collection.dart';
import 'package:chess_auto_prep/chess_core/pgn/study_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/core/pgn/pgn_collection_helpers.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_text.dart'
    show splitPgnIntoGames;

void main() {
  _headerHelperTests();
  test('Game and Train agree on indented CRLF course boundaries', () {
    const course =
        '[Event "?"]\r\n[White "Introduction"]\r\n\r\n1. d4 *\r\n'
        '  [Event "?"]\r\n[White "Quickstarter"]\r\n\r\n1. d4 Nf6 *';
    expect(parseMultiGamePgn(course).length, 2);
    expect(parseMultiGamePgn(course).length, splitPgnIntoGames(course).length);
  });

  group('mergeEditedGamesIntoDiskCopy', () {
    String game(String white, String black, String moves) =>
        '[Event "?"]\n[White "$white"]\n[Black "$black"]\n[Result "*"]\n\n$moves *\n';

    test('our edit lands and everything else on disk is kept verbatim', () {
      final disk =
          '${game('me', 'a', '1. e4 { theirs } e5')}\n'
          '${game('me', 'b', '1. d4 d5')}';
      final ours = [
        game('me', 'a', '1. e4 e5'),
        game('me', 'b', '1. d4 { mine } d5'),
      ];

      final merged = mergeEditedGamesIntoDiskCopy(
        diskContent: disk,
        gameTexts: ours,
        edited: {1},
      )!;

      expect(merged, contains('{ theirs }'), reason: 'their edit was reverted');
      expect(merged, contains('{ mine }'), reason: 'our edit did not land');
    });

    test('a game only on disk survives a merge that does not know it', () {
      final disk =
          '${game('me', 'a', '1. e4 e5')}\n'
          '${game('me', 'newcomer', '1. c4 c5')}';
      final merged = mergeEditedGamesIntoDiskCopy(
        diskContent: disk,
        gameTexts: [game('me', 'a', '1. e4 { mine } e5')],
        edited: {0},
      )!;

      expect(merged, contains('newcomer'));
      expect(merged, contains('{ mine }'));
    });

    test('the banner above the disk copy is the one that is kept', () {
      final disk = '; written by the reader\n\n${game('me', 'a', '1. e4 e5')}';
      final merged = mergeEditedGamesIntoDiskCopy(
        diskContent: disk,
        gameTexts: [game('me', 'a', '1. e4 { mine } e5')],
        edited: {0},
      )!;

      expect(merged.trimLeft(), startsWith('; written by the reader'));
    });

    test('an edit it cannot place safely is reported, not guessed', () {
      // Two games on disk with the same identity and a shape that no longer
      // matches ours: substituting either one could overwrite the wrong game.
      final twin = game('me', 'a', '1. e4 e5');
      final disk = '$twin\n$twin\n${game('me', 'c', '1. c4 c5')}';
      final unplaced = <int>[];
      final merged = mergeEditedGamesIntoDiskCopy(
        diskContent: disk,
        gameTexts: [game('me', 'a', '1. e4 { mine } e5')],
        edited: {0},
        unplaced: unplaced,
      )!;

      expect(unplaced, [0]);
      expect(merged, isNot(contains('{ mine }')));
      expect(splitPgnIntoGames(merged).length, 3, reason: 'nothing was lost');
    });

    test('a file with no games at all is not something to merge into', () {
      expect(
        mergeEditedGamesIntoDiskCopy(
          diskContent: '; someone emptied this\n',
          gameTexts: [game('me', 'a', '1. e4 e5')],
          edited: {0},
        ),
        isNull,
      );
    });
  });

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

    test('retains a banner before indented CRLF headers', () {
      const content =
          '\uFEFF; Reader banner\r\n% preserved escape\r\n\r\n  [Event "Indented"]\r\n\r\n1. e4 *';
      expect(parseMultiGamePgn(content), hasLength(1));
      expect(
        pgnCollectionPreamble(content),
        '; Reader banner\r\n% preserved escape',
      );
    });

    test('retains leading comments that the headerless splitter omits', () {
      const content = '; Reader banner\n\n1. e4 e5 *';
      expect(parseMultiGamePgn(content), hasLength(1));
      expect(pgnCollectionPreamble(content), '; Reader banner');
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

void _headerHelperTests() {
  group('upsertPgnHeader / removePgnHeader', () {
    const pgn = '[Event "?"]\n[White "A"]\n\n1. e4 *\n';

    test('inserts a missing header after the first line', () {
      expect(
        upsertPgnHeader(pgn, 'StudyRating', '3'),
        '[Event "?"]\n[StudyRating "3"]\n[White "A"]\n\n1. e4 *\n',
      );
    });

    test('replaces an existing header in place', () {
      final rated = upsertPgnHeader(pgn, 'StudyRating', '3');
      expect(
        upsertPgnHeader(rated, 'StudyRating', '5'),
        '[Event "?"]\n[StudyRating "5"]\n[White "A"]\n\n1. e4 *\n',
      );
    });

    test('leaves a single-line text alone and removes whole lines', () {
      expect(upsertPgnHeader('1. e4 *', 'StudyRating', '3'), '1. e4 *');
      final rated = upsertPgnHeader(pgn, 'StudyRating', '3');
      expect(removePgnHeader(rated, 'StudyRating'), pgn);
      expect(removePgnHeader(pgn, 'StudyRating'), pgn);
    });
  });

  group('buildMetadataOutput', () {
    const pgn = '[Event "?"]\n[StudyRating "2"]\n[StudySummary "old"]\n\n*\n';

    test('writes the rating and a quote-safe summary', () {
      final out = buildMetadataOutput([
        (pgn: pgn, rating: 4, summary: 'say "hi"'),
      ]).single;
      expect(out, contains('[StudyRating "4"]'));
      expect(out, contains('[StudySummary "say \'hi\'"]'));
    });

    test('clears both headers when the game has neither', () {
      final out = buildMetadataOutput([(pgn: pgn, rating: 0, summary: '')]);
      expect(out.single, '[Event "?"]\n\n*\n');
    });
  });

  group('sliceConfigWithoutChip', () {
    const white = HeaderFilterConfig(
      field: 'White',
      mode: MatchMode.contains,
      value: 'Carlsen',
    );
    const blank = HeaderFilterConfig(
      field: 'Black',
      mode: MatchMode.contains,
      value: '',
    );
    const config = SliceConfig(
      positionInput: 'p0',
      additionalPositions: ['', 'p1', 'p2'],
      matchAny: false,
      headerFilters: [blank, white],
      sequencePattern: 'e4 e5',
      sequenceGap: 2,
    );

    test('chips are removed in chipLabels order', () {
      expect(config.chipLabels, hasLength(5));

      final noPosition = sliceConfigWithoutChip(config, 0)!;
      expect(noPosition.positionInput, isNull);
      expect(noPosition.additionalPositions, ['', 'p1', 'p2']);

      // The blank additional position has no chip; chip 1 is p1.
      final noP1 = sliceConfigWithoutChip(config, 1)!;
      expect(noP1.additionalPositions, ['', 'p2']);
      expect(noP1.positionInput, 'p0');

      final noSequence = sliceConfigWithoutChip(config, 3)!;
      expect(noSequence.sequencePattern, isNull);
      expect(noSequence.sequenceGap, 2);

      final noHeader = sliceConfigWithoutChip(config, 4)!;
      expect(noHeader.headerFilters, [blank]);
      expect(noHeader.sequencePattern, 'e4 e5');
    });

    test('an index past the chips is refused', () {
      expect(sliceConfigWithoutChip(config, 5), isNull);
      expect(sliceConfigWithoutChip(config, -1), isNull);
    });
  });

  group('player detection', () {
    PgnGameEntry game(String white, String black) => PgnGameEntry(
      headers: {'White': white, 'Black': black},
      pgnText: '',
      studyRating: 0,
      studySummary: '',
    );

    test('detectProtagonistFrom names the player in every sampled game', () {
      expect(
        detectProtagonistFrom([game('A', 'B'), game('C', 'A'), game('A', '?')]),
        'A',
      );
      expect(detectProtagonistFrom([game('A', 'B'), game('C', 'D')]), isNull);
      expect(detectProtagonistFrom([game('A', 'B')]), isNull);
    });

    test('detectBothPlayersFrom lists the more frequent White first', () {
      expect(
        detectBothPlayersFrom([game('A', 'B'), game('A', 'B'), game('B', 'A')]),
        (player1: 'A', player2: 'B'),
      );
      expect(detectBothPlayersFrom([game('A', 'B'), game('A', 'C')]), isNull);
    });
  });
}
