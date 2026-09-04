import 'package:chess_auto_prep/features/engine_tournament/models/tournament_game.dart';
import 'package:chess_auto_prep/models/game_outcome.dart';
import 'package:chess_auto_prep/services/crosstable_builder.dart';
import 'package:flutter_test/flutter_test.dart';

TournamentGameRecord _game({
  required int index,
  required int white,
  required int black,
  required GameResult result,
}) => TournamentGameRecord(
  gameIndex: index,
  round: index + 1,
  whiteIndex: white,
  blackIndex: black,
  whiteName: 'W',
  blackName: 'B',
  result: result,
  termination: TerminationReason.checkmate,
  plies: 40,
  startedAt: DateTime(2026),
  durationMs: 1000,
);

void main() {
  group('buildCrosstable', () {
    test('scores a two-engine match from both sides', () {
      final table = buildCrosstable(
        ['A', 'B'],
        [
          _game(index: 0, white: 0, black: 1, result: GameResult.whiteWins),
          _game(index: 1, white: 1, black: 0, result: GameResult.draw),
          _game(index: 2, white: 0, black: 1, result: GameResult.blackWins),
          _game(index: 3, white: 1, black: 0, result: GameResult.draw),
        ],
      );

      final a = table.standings.firstWhere((r) => r.name == 'A');
      final b = table.standings.firstWhere((r) => r.name == 'B');
      expect(a.points, 2.0);
      expect(b.points, 2.0);
      expect(a.played, 4);
      expect(a.wins, 1);
      expect(a.draws, 2);
      expect(a.losses, 1);
      expect(a.scoreLabel, '2/4');
      // An even match implies no rating gap at all — and *positive* zero,
      // since negative zero renders with a sign ("+-0").
      expect(a.eloDiff, closeTo(0, 1e-9));
      expect(a.eloDiff!.isNegative, isFalse);
      expect(a.eloDiff!.toStringAsFixed(0), '0');
    });

    test('head-to-head cells record results in play order', () {
      final table = buildCrosstable(
        ['A', 'B'],
        [
          _game(index: 0, white: 0, black: 1, result: GameResult.whiteWins),
          _game(index: 1, white: 1, black: 0, result: GameResult.draw),
          _game(index: 2, white: 0, black: 1, result: GameResult.blackWins),
        ],
      );

      // A won game 1 as White, drew game 2, lost game 3 as White.
      expect(table.cell(0, 1)!.results, ['1', '=', '0']);
      // The same three games from B's side.
      expect(table.cell(1, 0)!.results, ['0', '=', '1']);
      expect(table.cell(0, 1)!.points, 1.5);
      expect(table.cell(1, 0)!.points, 1.5);
      expect(table.cell(0, 0), isNull);
    });

    test('ranks by points, then Sonneborn-Berger', () {
      // A and B both score 1.5/2; A's came against the stronger opponent.
      final table = buildCrosstable(
        ['A', 'B', 'C'],
        [
          _game(index: 0, white: 0, black: 1, result: GameResult.whiteWins),
          _game(index: 1, white: 0, black: 2, result: GameResult.draw),
          _game(index: 2, white: 1, black: 2, result: GameResult.whiteWins),
          _game(index: 3, white: 2, black: 1, result: GameResult.draw),
        ],
      );

      expect(table.standings.first.name, 'A');
      expect(table.standings.map((r) => r.rank), [1, 2, 3]);
      expect(
        table.standings.first.sonnebornBerger,
        greaterThan(table.standings[1].sonnebornBerger),
      );
    });

    test('a clean sweep implies no finite rating gap', () {
      final table = buildCrosstable(
        ['A', 'B'],
        [
          _game(index: 0, white: 0, black: 1, result: GameResult.whiteWins),
          _game(index: 1, white: 1, black: 0, result: GameResult.blackWins),
        ],
      );
      expect(table.standings.first.eloDiff, isNull);
      expect(table.standings.first.eloMargin, isNull);
    });

    test('an unfinished game counts as half a point each', () {
      final table = buildCrosstable(
        ['A', 'B'],
        [_game(index: 0, white: 0, black: 1, result: GameResult.unfinished)],
      );
      expect(table.standings.every((r) => r.points == 0.5), isTrue);
      expect(table.standings.every((r) => r.draws == 1), isTrue);
    });

    test('an empty tournament produces an empty table', () {
      expect(buildCrosstable(const [], const []).isEmpty, isTrue);
    });
  });

  group('likelihoodOfSuperiority', () {
    test('is 50% with no decisive games', () {
      expect(likelihoodOfSuperiority(0, 0), closeTo(0.5, 1e-9));
      expect(likelihoodOfSuperiority(3, 3), closeTo(0.5, 1e-9));
    });

    test('rises with the win margin', () {
      expect(
        likelihoodOfSuperiority(6, 1),
        greaterThan(likelihoodOfSuperiority(3, 1)),
      );
      expect(likelihoodOfSuperiority(10, 0), greaterThan(0.99));
    });
  });
}
