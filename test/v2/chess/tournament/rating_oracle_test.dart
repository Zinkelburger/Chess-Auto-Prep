// The old app is an oracle only; production v2 imports no legacy code.
import 'package:chess_auto_prep/services/crosstable_builder.dart' as oracle;
import 'package:chess_auto_prep/models/crosstable.dart' as legacy;
import 'package:chess_auto_prep/models/game_outcome.dart';
import 'package:chess_auto_prep/v2/chess/tournament/standings.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Result implements legacy.CrosstableGame {
  const _Result(this.result);
  @override
  final GameResult result;
  @override
  int get whiteIndex => 0;
  @override
  int get blackIndex => 1;
}

void main() {
  test(
    'fresh arithmetic matches shipped rating reports on representative records',
    () {
      for (final (wins, draws, losses) in [
        (7, 4, 3),
        (60, 20, 20),
        (1, 0, 1),
        (4, 3, 21),
        (0, 7, 0),
        (6, 0, 0),
      ]) {
        final expected = oracle
            .buildCrosstable(
              ['A', 'B'],
              [
                for (var i = 0; i < wins; i++)
                  const _Result(GameResult.whiteWins),
                for (var i = 0; i < draws; i++) const _Result(GameResult.draw),
                for (var i = 0; i < losses; i++)
                  const _Result(GameResult.blackWins),
              ],
            )
            .standings
            .firstWhere((r) => r.engineIndex == 0);
        final actual = MatchScore(wins, draws, losses);
        expect(
          actual.elo,
          expected.eloDiff == null ? isNull : closeTo(expected.eloDiff!, 1e-8),
        );
        expect(
          actual.margin,
          expected.eloMargin == null
              ? isNull
              : closeTo(expected.eloMargin!, 1e-4),
        );
        expect(
          actual.superiority,
          closeTo(expected.likelihoodOfSuperiority, 2e-7),
        );
      }
    },
  );
}
