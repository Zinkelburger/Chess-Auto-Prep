import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/pgn_parsing_service.dart';
import 'package:chess_auto_prep/core/slice_filter_controller.dart';

/// Robustness coverage for the slice/sequence/header matching *functions* and
/// the [SliceFilterController] numeric gap seam. Focus: negative / zero / huge
/// gaps, zero-length and oversized sequences, malformed move tokens, malformed
/// FEN/SAN position input, contradictory filters, and the numeric comparison
/// used for rating cutoffs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── parseSequenceGroups: tokenizing user sequence input ─────────────────
  group('parseSequenceGroups — malformed / degenerate sequence text', () {
    test('empty / whitespace / result-only text yields no groups', () {
      expect(parseSequenceGroups(''), isEmpty);
      expect(parseSequenceGroups('    '), isEmpty);
      expect(parseSequenceGroups('1-0'), isEmpty);
      expect(parseSequenceGroups('1/2-1/2  *'), isEmpty);
    });

    test('a bare [gap] token (zero-length groups) collapses to no groups', () {
      expect(parseSequenceGroups('[gap]'), isEmpty);
      expect(parseSequenceGroups('[gap] [gap] [gap]'), isEmpty);
    });

    test('move numbers and result tokens are stripped, moves survive', () {
      expect(parseSequenceGroups('1. e4 e5 2. Nf3 *'), [
        ['e4', 'e5', 'Nf3'],
      ]);
    });

    test('empty groups between gaps are dropped, not emitted as []', () {
      expect(parseSequenceGroups('e4 [gap] [gap] Nc6'), [
        ['e4'],
        ['Nc6'],
      ]);
    });

    test(
      'garbage/illegal move tokens are still returned verbatim (no validation)',
      () {
        // parseSequenceGroups only tokenizes; SAN legality is not its job.
        expect(
          parseSequenceGroups('zzz @@@ 99'),
          [
            ['zzz', '@@@', '99'],
          ],
          reason:
              'only "<digits>." move-number prefixes are stripped; a bare '
              '"99" and junk words survive as tokens',
        );
      },
    );

    test('an enormous sequence tokenizes without blowing up', () {
      final huge = List.filled(20000, 'e4').join(' ');
      final groups = parseSequenceGroups(huge);
      expect(groups, hasLength(1));
      expect(groups.first, hasLength(20000));
    });
  });

  // ── gameMatchesSequence: the gap (ply distance) numeric knob ────────────
  group('gameMatchesSequence — gap bounds between groups', () {
    // 1.e4 e5 2.Nf3 Nc6 → mainline SAN indices: e4=0, e5=1, Nf3=2, Nc6=3.
    const pgn = '[Event "t"]\n\n1. e4 e5 2. Nf3 Nc6 *';

    List<List<String>> twoGroups() => [
      ['e4'],
      ['Nc6'],
    ];

    test('empty groups match every game regardless of gap', () {
      expect(gameMatchesSequence(pgn, const [], 4), isTrue);
      expect(gameMatchesSequence(pgn, const [], -100), isTrue);
    });

    test('a single group ignores the gap entirely', () {
      // gi == 0 searches the whole mainline, so gap 0 / negative are irrelevant.
      expect(
        gameMatchesSequence(pgn, [
          ['Nc6'],
        ], 0),
        isTrue,
      );
      expect(
        gameMatchesSequence(pgn, [
          ['Nc6'],
        ], -50),
        isTrue,
      );
    });

    test('a wide-enough gap connects the two groups', () {
      // e4 ends at ply 1; Nc6 is at ply 3 → needs gap >= 2.
      expect(gameMatchesSequence(pgn, twoGroups(), 4), isTrue);
      expect(gameMatchesSequence(pgn, twoGroups(), 2), isTrue);
    });

    test('too-small a gap between groups yields no match (graceful)', () {
      expect(gameMatchesSequence(pgn, twoGroups(), 1), isFalse);
      expect(gameMatchesSequence(pgn, twoGroups(), 0), isFalse);
    });

    test('a negative gap can never bridge two groups but does not throw', () {
      expect(gameMatchesSequence(pgn, twoGroups(), -1), isFalse);
      expect(gameMatchesSequence(pgn, twoGroups(), -1000000), isFalse);
    });

    test('an absurdly large gap is clamped and still matches', () {
      expect(gameMatchesSequence(pgn, twoGroups(), 1 << 40), isTrue);
    });

    test('a group longer than the game never matches (no range error)', () {
      final tooLong = [List.filled(50, 'e4')];
      expect(gameMatchesSequence(pgn, tooLong, 4), isFalse);
    });

    test('malformed PGN degrades to no-match, never throws', () {
      expect(gameMatchesSequence('not a pgn at all', twoGroups(), 4), isFalse);
      expect(gameMatchesSequence('', twoGroups(), 4), isFalse);
    });
  });

  // ── matchesField: header comparison, incl. numeric-cutoff semantics ─────
  group('matchesField — mode/edge behavior', () {
    test('invalid regex degrades to false instead of throwing', () {
      expect(matchesField('anything', '(unclosed', MatchMode.regex), isFalse);
      expect(matchesField('anything', '[z-a]', MatchMode.regex), isFalse);
    });

    test('contains/exact are case-insensitive', () {
      expect(matchesField('Carlsen', 'CARL', MatchMode.contains), isTrue);
      expect(matchesField('Carlsen', 'carlsen', MatchMode.exact), isTrue);
    });

    // REGRESSION GUARD (was a real, user-facing defect; now fixed):
    //   matchesField previously compared MatchMode.after/before with
    //   String.compareTo, so numeric header cutoffs (WhiteElo/BlackElo/
    //   StudyRating) were LEXICOGRAPHIC — "≥ 500" wrongly excluded a 2400 game
    //   ("2400" < "500") and "≤ 900" wrongly passed a 1000 game. It's now a
    //   numeric compare when both sides parse as num (dates fall back to the
    //   correct string compare). Location: pgn_parsing_service.dart, after/before.
    group('rating cutoffs compare numerically (cross-magnitude safe)', () {
      test('">= 500" INCLUDES a 2400 Elo', () {
        expect(
          matchesField('2400', '500', MatchMode.after),
          isTrue,
          reason: 'numerically 2400 >= 500',
        );
      });

      test('"<= 900" EXCLUDES a 1000 Elo', () {
        expect(
          matchesField('1000', '900', MatchMode.before),
          isFalse,
          reason: 'numerically 1000 > 900',
        );
      });

      test('equal-length cutoffs also behave numerically', () {
        expect(matchesField('2400', '2000', MatchMode.after), isTrue);
        expect(matchesField('2400', '2500', MatchMode.before), isTrue);
      });
    });

    test('Date after/before works lexicographically on YYYY.MM.DD', () {
      // Sortable date strings compare correctly under compareTo — the numeric
      // fix above must preserve this.
      expect(matchesField('2024.05.10', '2020', MatchMode.after), isTrue);
      expect(matchesField('1999.12.31', '2000', MatchMode.before), isTrue);
    });
  });

  // ── parseTargetFen: FEN-or-SAN position filter input ────────────────────
  group('parseTargetFen — malformed position input', () {
    test('null / empty input yields null (no filter)', () {
      expect(parseTargetFen(null), isNull);
      expect(parseTargetFen(''), isNull);
      expect(parseTargetFen('   '), isNull);
    });

    test('a malformed FEN (has slash) yields null, never throws', () {
      expect(parseTargetFen('this/is/not/a/fen'), isNull);
      expect(parseTargetFen('8/8/8/8 w - - 0 1'), isNull);
    });

    test('a malformed SAN sequence yields null, never throws', () {
      expect(parseTargetFen('e4 e5 Zz9'), isNull);
      expect(parseTargetFen('(((('), isNull);
      expect(parseTargetFen('e4 xx'), isNull);
    });

    test('a legal SAN sequence produces a normalized target FEN', () {
      final fen = parseTargetFen('1. e4 e5 2. Nf3');
      expect(fen, isNotNull);
      expect(fen, contains('/'));
    });
  });

  // ── computeSliceMatches: end-to-end (isolate) with degenerate inputs ────
  group('computeSliceMatches — empty / contradictory / bad-gap filters', () {
    List<GameRecord> games() => [
      (
        headers: {'White': 'A', 'Black': 'B', 'WhiteElo': '2400'},
        pgnText: '[Event "t"]\n\n1. e4 e5 2. Nf3 Nc6 *',
      ),
      (
        headers: {'White': 'C', 'Black': 'D', 'WhiteElo': '1200'},
        pgnText: '[Event "t"]\n\n1. d4 d5 *',
      ),
    ];

    test('no filters at all returns every game index', () async {
      final idx = await computeSliceMatches(
        games: games(),
        filters: const [],
        seqGroups: const [],
        seqGap: 4,
      );
      expect(idx, [0, 1]);
    });

    test('a blank-valued filter is ignored (treated as no filter)', () async {
      final idx = await computeSliceMatches(
        games: games(),
        filters: const [(field: 'White', mode: MatchMode.contains, value: '')],
        seqGroups: const [],
        seqGap: 4,
      );
      expect(idx, [0, 1]);
    });

    test('contradictory Elo cutoffs (min > max) exclude everything', () async {
      // WhiteElo >= 3000 AND WhiteElo <= 100 can never both hold.
      final idx = await computeSliceMatches(
        games: games(),
        filters: const [
          (field: 'WhiteElo', mode: MatchMode.after, value: '3000'),
          (field: 'WhiteElo', mode: MatchMode.before, value: '100'),
        ],
        seqGroups: const [],
        seqGap: 4,
      );
      expect(idx, isEmpty);
    });

    test(
      'a negative seqGap with two groups excludes all, does not throw',
      () async {
        final idx = await computeSliceMatches(
          games: games(),
          filters: const [],
          seqGroups: [
            ['e4'],
            ['Nc6'],
          ],
          seqGap: -5,
        );
        expect(idx, isEmpty);
      },
    );

    test('an oversized seqGap still matches the reachable sequence', () async {
      final idx = await computeSliceMatches(
        games: games(),
        filters: const [],
        seqGroups: [
          ['e4'],
          ['Nc6'],
        ],
        seqGap: 1 << 30,
      );
      expect(idx, [0]);
    });
  });

  // ── SliceFilterController: the gap text → int seam ──────────────────────
  group('SliceFilterController.sequenceGap — malformed gap text', () {
    test('blank / non-numeric / decimal gap text falls back to 4', () {
      final c = SliceFilterController();
      addTearDown(c.dispose);

      c.gapText.text = '';
      expect(c.sequenceGap, 4);
      c.gapText.text = 'abc';
      expect(c.sequenceGap, 4, reason: 'non-numeric gap → default');
      c.gapText.text = '3.5';
      expect(c.sequenceGap, 4, reason: 'a decimal is not an int → default');
    });

    test('an integer-overflowing gap string falls back to 4', () {
      final c = SliceFilterController();
      addTearDown(c.dispose);
      c.gapText.text = '99999999999999999999999999';
      expect(
        c.sequenceGap,
        4,
        reason: 'int.tryParse returns null past 2^63 → default gap',
      );
    });

    test(
      'a negative gap string is accepted verbatim (int.tryParse allows it)',
      () {
        final c = SliceFilterController();
        addTearDown(c.dispose);
        c.gapText.text = '-3';
        expect(
          c.sequenceGap,
          -3,
          reason: 'the controller does not clamp; matching code tolerates it',
        );
      },
    );

    test('buildConfig carries the parsed gap through only with a sequence', () {
      final c = SliceFilterController();
      addTearDown(c.dispose);
      c.sequenceText.text = 'e4 Nc6';
      c.gapText.text = '-2';
      final cfg = c.buildConfig();
      expect(cfg.sequenceGap, -2);
      expect(cfg.sequencePattern, isNotNull);
    });
  });

  // ── SliceFilterController: position input parsing seam ──────────────────
  group('SliceFilterController — position input parsing', () {
    test('malformed FEN input parses to an error, not a crash', () {
      final c = SliceFilterController();
      addTearDown(c.dispose);
      c.positionText.text = 'bogus/fen/string';
      expect(c.positionParse.isValid, isFalse);
      expect(c.hasPositionFilter, isFalse);
    });

    test('a legal SAN sequence becomes an active position filter', () {
      final c = SliceFilterController();
      addTearDown(c.dispose);
      c.positionText.text = '1. e4 e5 2. Nf3';
      expect(c.hasPositionFilter, isTrue);
      expect(c.positionFen, isNotNull);
    });

    test('clearing empties the filter without error', () {
      final c = SliceFilterController();
      addTearDown(c.dispose);
      c.positionText.text = 'e4';
      c.clearPosition();
      expect(c.hasPositionFilter, isFalse);
    });
  });
}
