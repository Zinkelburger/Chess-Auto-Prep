import 'package:chess_auto_prep/features/engine_tournament/models/engine_spec.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_config.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/engine_tournament_runner.dart';
import 'package:flutter_test/flutter_test.dart';

TournamentConfig _config({
  int engines = 2,
  int gamesPerPairing = 4,
  bool alternateColors = true,
  TournamentFormat format = TournamentFormat.roundRobin,
}) => TournamentConfig(
  name: 'T',
  gamesPerPairing: gamesPerPairing,
  alternateColors: alternateColors,
  format: format,
  engines: [
    for (var i = 0; i < engines; i++)
      EngineSpec(id: 'e$i', name: 'E$i', executablePath: '/bin/e$i'),
  ],
);

void main() {
  group('buildSchedule', () {
    test('a two-engine match alternates colours every game', () {
      final schedule = buildSchedule(_config());
      expect(schedule.length, 4);
      expect(schedule.map((g) => g.whiteIndex), [0, 1, 0, 1]);
      expect(schedule.map((g) => g.blackIndex), [1, 0, 1, 0]);
      expect(schedule.map((g) => g.round), [1, 2, 3, 4]);
      expect(schedule.map((g) => g.index), [0, 1, 2, 3]);
    });

    test('holding colours fixed is opt-out, not the default', () {
      final schedule = buildSchedule(_config(alternateColors: false));
      expect(schedule.every((g) => g.whiteIndex == 0), isTrue);
    });

    test('a round robin plays every pairing before repeating one', () {
      final schedule = buildSchedule(_config(engines: 3, gamesPerPairing: 2));
      expect(schedule.length, 6);
      // Round 1 covers all three pairings, then round 2 repeats them.
      expect(schedule.take(3).every((g) => g.round == 1), isTrue);
      expect(schedule.skip(3).every((g) => g.round == 2), isTrue);
      final firstRound = schedule
          .take(3)
          .map((g) => '${g.whiteIndex}-${g.blackIndex}')
          .toSet();
      expect(firstRound, {'0-1', '0-2', '1-2'});
    });

    test('a gauntlet only pairs the first engine with the rest', () {
      final schedule = buildSchedule(
        _config(
          engines: 4,
          gamesPerPairing: 1,
          format: TournamentFormat.gauntlet,
        ),
      );
      expect(schedule.length, 3);
      expect(schedule.every((g) => g.whiteIndex == 0), isTrue);
      expect(schedule.map((g) => g.blackIndex), [1, 2, 3]);
    });

    test('totalGames agrees with the schedule it describes', () {
      final config = _config(engines: 4, gamesPerPairing: 3);
      expect(buildSchedule(config).length, config.totalGames);
    });
  });
}
