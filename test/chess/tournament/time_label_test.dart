import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('time controls read the way a run plays them, defaults included', () {
    expect(describeTime(const {}), '2 s / move');
    expect(
      describeTime(const {
        'kind': 'incremental',
        'baseMs': 10000,
        'incrementMs': 100,
      }),
      '10 s + 0.1 s',
    );
    expect(
      describeTime(const {
        'kind': 'incremental',
        'baseMs': 600000,
        'incrementMs': 10000,
        'movesPerSession': 40,
      }),
      '40 moves in 600 s + 10 s',
    );
    expect(
      describeTime(const {'kind': 'fixedNodes', 'nodes': 1000000}),
      '1M nodes',
    );
    expect(describeTime(const {'kind': 'fixedDepth', 'depth': 12}), 'Depth 12');
  });

  test('a run names its preset, its format and its games per pairing', () {
    TournamentConfig run(Map<String, Object?> time, {String? format}) =>
        TournamentConfig({
          'timeControl': time,
          'format': ?format,
          'gamesPerPairing': 4,
        });
    final blitz = tournamentTimePresets.firstWhere((p) => p.label == 'Blitz');
    expect(run(blitz.time).timeLabel, 'Blitz · 60 s + 0.6 s');
    expect(run(const {}).timeLabel, '2 s / move');
    expect(
      run(const {'kind': 'movetime', 'movetimeMs': 1500}).timeLabel,
      '1.5 s / move',
    );
    expect(run(const {}).formatLabel, 'Round robin · 4 games per pairing');
    expect(
      run(const {}, format: 'gauntlet').formatLabel,
      'Gauntlet · 4 games per pairing',
    );
  });

  test('sudden-death presets leave movesPerSession out, as v1 writes them', () {
    // v1 reads a stored 0 as a 0-move period and divides by it.
    for (final preset in tournamentTimePresets) {
      final moves = preset.time['movesPerSession'];
      expect(
        moves == null || (moves is num && moves > 0),
        isTrue,
        reason: preset.label,
      );
    }
  });
}
