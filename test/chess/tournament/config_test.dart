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

  group('a tournament that can run', () {
    TournamentConfig two([Map<String, Object?> extra = const {}]) =>
        TournamentConfig({
          'name': 'Match',
          'engines': [
            TournamentEngine.bundled('A').json,
            TournamentEngine.bundled('B').json,
          ],
          ...extra,
        });
    TournamentConfig engines(
      int count, [
      Map<String, Object?> engine = const {},
    ]) => TournamentConfig({
      'name': 'Match',
      'engines': [
        for (var i = 0; i < count; i++)
          {...TournamentEngine.bundled('E$i').json, ...engine},
      ],
    });

    test('plays ten games a pairing unless told', () {
      expect(two().gamesPerPairing, 10);
      expect(two().problem, isNull);
    });

    test('has 2 to 32 engines', () {
      expect(engines(1).problem, 'Pick 2–32 engines.');
      expect(engines(33).problem, 'Pick 2–32 engines.');
      expect(engines(32, {'threads': 1}).problem, isNot('Pick 2–32 engines.'));
    });

    test('keeps each number inside its range, ends included', () {
      expect(two({'gamesPerPairing': 0}).problem, isNotNull);
      expect(two({'gamesPerPairing': 1001}).problem, isNotNull);
      expect(two({'concurrency': 64}).problem, isNull);
      expect(two({'concurrency': 65}).problem, isNotNull);
      expect(
        two({
          'adjudication': {'maxMoves': 0},
        }).problem,
        isNotNull,
      );
      expect(
        two({
          'adjudication': {'maxMoves': 10001},
        }).problem,
        isNotNull,
      );
      const cores = 'Use 1–1024 cores and 1–65536 MB per engine.';
      expect(engines(2, {'threads': 1024}).problem, isNull);
      expect(engines(2, {'threads': 1025}).problem, cores);
      expect(engines(2, {'threads': 0}).problem, cores);
      expect(engines(2, {'hashMb': 1}).problem, isNull);
      expect(engines(2, {'hashMb': 0}).problem, cores);
    });

    test('alternates colours each round only when asked', () {
      List<int> whites(TournamentConfig config) => [
        for (final game in config.schedule) game.white,
      ];
      expect(whites(two({'gamesPerPairing': 2})), [0, 1]);
      expect(whites(two({'gamesPerPairing': 2, 'alternateColors': false})), [
        0,
        0,
      ]);
    });
  });

  test('a preset that names its own time is described as it is named', () {
    for (final preset in tournamentTimePresets.where(
      (p) => !['Bullet', 'Blitz', 'Rapid', 'Classical'].contains(p.label),
    )) {
      expect(describeTime(preset.time), preset.label);
    }
  });

  test('a node count is written in thousands where it is whole ones', () {
    expect(
      describeTime(const {'kind': 'fixedNodes', 'nodes': 5000}),
      '5k nodes',
    );
    expect(
      describeTime(const {'kind': 'fixedNodes', 'nodes': 1500}),
      '1500 nodes',
    );
  });
}
