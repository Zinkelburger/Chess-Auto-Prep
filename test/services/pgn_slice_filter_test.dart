/// Slicing a collection: header predicates, move-sequence patterns and the
/// combined slice computation.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_position_replay.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_slice_filter.dart';
import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_filter.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';

void main() {
  group('movesMatchSequence', () {
    const moves = ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6'];

    test('the first group may start anywhere, later ones within the gap', () {
      expect(
        movesMatchSequence(moves, const [
          ['Nf3', 'd6'],
          ['Nxd4'],
        ], 2),
        isTrue,
      );
      expect(
        movesMatchSequence(moves, const [
          ['Nf3', 'd6'],
          ['Nxd4'],
        ], 1),
        isFalse,
        reason: 'd4 cxd4 is two plies of gap',
      );
    });

    test('a group longer than the game never matches', () {
      expect(
        movesMatchSequence(
          const ['e4'],
          const [
            ['e4', 'c5'],
          ],
          0,
        ),
        isFalse,
      );
      expect(movesMatchSequence(moves, const [], 0), isTrue);
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
}
