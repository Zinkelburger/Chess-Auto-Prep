import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TournamentConfig fifteen([Map<String, Object?> extra = const {}]) =>
      TournamentConfig({
        'name': 'Match',
        'engines': [
          for (var i = 0; i < 15; i++) TournamentEngine.bundled('E$i').json,
        ],
        'gamesPerPairing': 1000,
        ...extra,
      });

  test('the game cap counts the games the format plays', () {
    final gauntlet = fifteen({'format': 'gauntlet'});
    expect(gauntlet.gameCount, 14000);
    expect(gauntlet.problem, isNull);
    for (final roundRobin in [
      fifteen(),
      fifteen({'format': 'roundRobin'}),
    ]) {
      expect(roundRobin.gameCount, 105000);
      expect(roundRobin.problem, 'Limit a run to 100000 games.');
    }
  });
}
