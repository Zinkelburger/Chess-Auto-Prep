import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/course/model_game_selector.dart';
import 'package:chess_auto_prep/services/generation/pgn_freq_map.dart';
import 'package:flutter_test/flutter_test.dart';

import '../generation_test_helpers.dart';

/// A White repertoire that plays 1.e4 and meets 1...e5 with 2.Nf3, 1...c5 with
/// 2.Nf3.  `d4` exists in the tree but is not selected.
BuildTree _repertoire() {
  final t = StandardTree();
  t.e4.isRepertoireMove = true;
  t.e4e5nf3.isRepertoireMove = true;
  t.e4c5nf3.isRepertoireMove = true;
  return t.toTree();
}

PgnGameRecord _game({
  required List<String> moves,
  String white = 'White, W',
  String black = 'Black, B',
  int elo = 2500,
  GameOutcome? outcome = GameOutcome.whiteWin,
}) => PgnGameRecord(
  white: white,
  black: black,
  whiteElo: elo,
  blackElo: elo,
  event: 'Test',
  date: '2020.01.01',
  outcome: outcome,
  movesSan: moves,
);

/// The selector takes any candidate games; a scanned database's reservoir
/// is one source, so mirror that here.
Iterable<PgnGameRecord> _database(List<PgnGameRecord> games) {
  final map = PgnFreqMap();
  map.games.addAllUnchecked(games);
  return map.games.entries;
}

void main() {
  group('ModelGameSelector', () {
    const selector = ModelGameSelector(playAsWhite: true, minFollowedPlies: 3);

    test('keeps games that follow the repertoire', () {
      final database = _database([
        _game(moves: ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']),
      ]);

      final picked = selector.select(database, _repertoire(), limit: 3);

      expect(picked, hasLength(1));
      expect(picked.single.followedPlies, 3);
    });

    test('drops a game that leaves the repertoire immediately', () {
      final database = _database([
        _game(moves: ['d4', 'd5', 'c4', 'e6']),
      ]);

      expect(selector.select(database, _repertoire(), limit: 3), isEmpty);
    });

    test('stops counting when OUR move is not the repertoire move', () {
      // d4 is in the tree but was not selected, so the game never enters.
      final database = _database([
        _game(moves: ['d4', 'd5', 'c4']),
      ]);

      expect(selector.select(database, _repertoire(), limit: 3), isEmpty);
    });

    test('prefers the game that stays in the repertoire longest', () {
      final database = _database([
        _game(moves: ['e4', 'e5', 'Nf3', 'x'], white: 'Shallow'),
        _game(moves: ['e4', 'c5', 'Nf3', 'd6', 'd4'], white: 'Deep'),
      ]);

      // Both follow 3 plies of our moves; the tree only reaches ply 3, so
      // depth ties and the tie-break must be by result then rating.
      final picked = selector.select(database, _repertoire(), limit: 2);
      expect(picked, hasLength(2));
    });

    test('prefers our wins, then draws, over our losses', () {
      final database = _database([
        _game(
          moves: ['e4', 'e5', 'Nf3'],
          white: 'Lost',
          outcome: GameOutcome.blackWin,
        ),
        _game(
          moves: ['e4', 'c5', 'Nf3'],
          white: 'Drew',
          outcome: GameOutcome.draw,
        ),
        _game(
          moves: ['e4', 'e5', 'Nf3'],
          white: 'Won',
          outcome: GameOutcome.whiteWin,
        ),
      ]);

      final picked = selector.select(database, _repertoire(), limit: 3);
      expect(picked.map((g) => g.record.white), ['Won', 'Drew', 'Lost']);
    });

    test('breaks remaining ties by player strength', () {
      final database = _database([
        _game(moves: ['e4', 'e5', 'Nf3'], white: 'Weak', elo: 2200),
        _game(moves: ['e4', 'e5', 'Nf3'], white: 'Strong', elo: 2750),
      ]);

      final picked = selector.select(database, _repertoire(), limit: 2);
      expect(picked.first.record.white, 'Strong');
    });

    test('covers different variations before repeating one', () {
      final database = _database([
        _game(moves: ['e4', 'e5', 'Nf3'], white: 'E5 best', elo: 2800),
        _game(moves: ['e4', 'e5', 'Nf3'], white: 'E5 second', elo: 2750),
        _game(moves: ['e4', 'c5', 'Nf3'], white: 'C5 only', elo: 2400),
      ]);

      final picked = selector.select(database, _repertoire(), limit: 2);

      expect(
        picked.map((g) => g.record.white),
        containsAll(['E5 best', 'C5 only']),
        reason: 'a weaker game in a fresh variation beats a second in the same',
      );
    });

    test('honours the limit', () {
      final database = _database([
        for (var i = 0; i < 10; i++)
          _game(moves: ['e4', 'e5', 'Nf3'], white: 'P$i', elo: 2400 + i),
      ]);

      expect(selector.select(database, _repertoire(), limit: 3), hasLength(3));
    });

    group('departure', () {
      test('our side leaving: the repertoire move and its mainline', () {
        // After 1.e4 e5 the repertoire plays 2.Nf3; the game played 2.Bc4.
        final picked = selector.select(
          _database([
            _game(moves: ['e4', 'e5', 'Bc4', 'Nf6', 'd3']),
          ]),
          _repertoire(),
          limit: 1,
        );
        // minFollowedPlies 3 would drop it, so loosen for this check.
        expect(picked, isEmpty);
        const loose = ModelGameSelector(playAsWhite: true, minFollowedPlies: 2);
        final game = loose
            .select(
              _database([
                _game(moves: ['e4', 'e5', 'Bc4', 'Nf6', 'd3']),
              ]),
              _repertoire(),
              limit: 1,
            )
            .single;
        expect(game.followedPlies, 2);
        final d = game.departure!;
        expect(d.kind, DepartureKind.ours);
        expect(d.index, 2);
        expect(d.gameSan, 'Bc4');
        expect(d.repertoireSan, 'Nf3');
        expect(d.repertoireLine, ['Nf3']); // the tree ends after 2.Nf3
        expect(d.preparedReplies, isEmpty);
      });

      test('opponent leaving: the replies we prepare, most likely first', () {
        const loose = ModelGameSelector(playAsWhite: true, minFollowedPlies: 1);
        final game = loose
            .select(
              _database([
                _game(moves: ['e4', 'c6', 'd4', 'd5']),
              ]),
              _repertoire(),
              limit: 1,
            )
            .single;
        expect(game.followedPlies, 1);
        final d = game.departure!;
        expect(d.kind, DepartureKind.opponent);
        expect(d.index, 1);
        expect(d.gameSan, 'c6');
        expect(d.preparedReplies, ['e5', 'c5']); // 0.55 before 0.35
        expect(d.repertoireLine, isEmpty);
      });

      test('a game that stays inside the repertoire has no departure', () {
        final game = selector
            .select(
              _database([
                _game(moves: ['e4', 'e5', 'Nf3']),
              ]),
              _repertoire(),
              limit: 1,
            )
            .single;
        expect(game.departure, isNull);
        // Running past the tree is not a departure either.
        final past = selector
            .select(
              _database([
                _game(moves: ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']),
              ]),
              _repertoire(),
              limit: 1,
            )
            .single;
        expect(past.departure, isNull);
      });
    });

    test('an empty database and a zero limit both yield nothing', () {
      expect(selector.select(_database([]), _repertoire(), limit: 5), isEmpty);
      expect(
        selector.select(
          _database([
            _game(moves: ['e4', 'e5', 'Nf3']),
          ]),
          _repertoire(),
          limit: 0,
        ),
        isEmpty,
      );
    });
  });
}
