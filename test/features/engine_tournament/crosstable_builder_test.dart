import 'package:chess_auto_prep/features/engine_tournament/models/tournament_game.dart';
import 'package:chess_auto_prep/models/crosstable.dart';
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

  group('eloMargin — the 95% confidence interval', () {
    /// Every game with A as White, so A's record is exactly this W/D/L split.
    List<TournamentGameRecord> record(int wins, int draws, int losses) {
      final games = <TournamentGameRecord>[];
      void add(GameResult result, int n) {
        for (var i = 0; i < n; i++) {
          games.add(
            _game(index: games.length, white: 0, black: 1, result: result),
          );
        }
      }

      add(GameResult.whiteWins, wins);
      add(GameResult.draw, draws);
      add(GameResult.blackWins, losses);
      return games;
    }

    StandingsRow rowA(int wins, int draws, int losses) => buildCrosstable([
      'A',
      'B',
    ], record(wins, draws, losses)).standings.firstWhere((r) => r.name == 'A');

    test('is the score interval carried through the Elo curve', () {
      // 60W/20D/20L. Derived by hand, without reference to the code:
      //   score       f = (60 + 20/2) / 100                    = 0.70
      //   spread      S = 60(1-.7)^2 + 20(0-.7)^2 + 20(.5-.7)^2
      //                 = 5.4 + 9.8 + 0.8                      = 16.0
      //   per game    o = sqrt(16/100)                         = 0.40
      //   of the mean   o/sqrt(100)                            = 0.04
      //   95% band    0.70 +- 1.959964 * 0.04 = [0.621601, 0.778399]
      //   in Elo      400*log10(f/(1-f))      = [86.2250, 218.2518]
      //   half-width  (218.2518 - 86.2250)/2                   = 66.01
      final a = rowA(60, 20, 20);
      expect(a.played, 100);
      expect(a.eloDiff, closeTo(147.19, 0.01)); // 400*log10(0.7/0.3)
      expect(a.eloMargin, closeTo(66.01, 0.02));
    });

    test('narrows like 1/sqrt(n): quadruple the games, halve the bar', () {
      final small = rowA(15, 5, 5).eloMargin!; // 25 games, 70%
      final mid = rowA(60, 20, 20).eloMargin!; // 100 games, 70%
      final large = rowA(240, 80, 80).eloMargin!; // 400 games, 70%
      expect(small, greaterThan(mid));
      expect(mid, greaterThan(large));
      // Not exactly 2 because the logistic transform is not linear, but the
      // standard error underneath it is 1/sqrt(n) and this is what that means.
      expect(small / mid, closeTo(2.0, 0.25));
      expect(mid / large, closeTo(2.0, 0.25));
    });

    test('is a band with the estimate strictly inside it', () {
      final a = rowA(50, 0, 50);
      expect(a.eloDiff, closeTo(0, 1e-9));
      final margin = a.eloMargin!;
      // low < estimate < high, i.e. the half-width is positive and the two
      // ends have not been swapped or collapsed onto the point estimate.
      expect(margin, greaterThan(0));
      // A dead-even 100-game match is worth about +-69 Elo of uncertainty.
      expect(margin, closeTo(68.99, 0.02));
    });

    test('a near-sweep stays finite instead of running off to infinity', () {
      final a = rowA(99, 0, 1);
      expect(a.eloDiff, closeTo(798.25, 0.01)); // 400*log10(99)
      final margin = a.eloMargin!;
      expect(margin.isFinite, isTrue);
      expect(margin, greaterThan(0));
    });
  });
}
