import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/workspace/engine_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  EngineLine best({int depth = 20, int? nodes, int? nps, Score? score}) =>
      EngineLine(
        multiPv: 1,
        depth: depth,
        score: score ?? const Centipawns(20),
        pv: const ['e2e4'],
        nodes: nodes,
        nps: nps,
      );

  test('speed and counts are written short', () {
    expect(speedText(850000), '850 kN/s');
    expect(speedText(1234567), '1.2 MN/s');
    expect(speedText(23456789), '23 MN/s');
    expect(countText(950), '950');
    expect(countText(56000), '56k');
    expect(countText(1234567), '1.2M');
    expect(countText(345000000), '345M');
    expect(countText(2100000000), '2.1G');
  });

  test('the status says only what the engine has said', () {
    expect(engineRunningStatus('Stockfish 19', null), 'Stockfish 19');
    expect(
      engineRunningStatus('Stockfish 19', best(depth: 18)),
      'Depth 18 · Stockfish 19',
    );
    expect(
      engineRunningStatus(
        'Stockfish 19',
        best(depth: 31, nodes: 456000000, nps: 15200000),
      ),
      'Depth 31 · 15 MN/s · 456M nodes · Stockfish 19',
    );
  });

  test('a finished game and a found mate leave the depth out', () {
    expect(
      engineRunningStatus(
        'Stockfish 19',
        best(depth: 0, score: const MateIn(0)),
      ),
      'Stockfish 19',
    );
    expect(
      engineRunningStatus(
        'Stockfish 19',
        best(depth: 245, score: const MateIn(2), nps: 900000),
      ),
      '900 kN/s · Stockfish 19',
    );
  });

  test('the engine standing in says why last', () {
    expect(
      engineRunningStatus('Stockfish 19', null, notice: 'Komodo did not start'),
      'Stockfish 19 · Komodo did not start',
    );
  });

  test('a narrow pane drops the nodes, then the name, then the speed', () {
    expect(
      engineStatusChoices(
        'Stockfish 19',
        best(depth: 18, nodes: 6300000, nps: 1300000),
      ),
      [
        'Depth 18 · 1.3 MN/s · 6.3M nodes · Stockfish 19',
        'Depth 18 · 1.3 MN/s · Stockfish 19',
        'Depth 18 · 1.3 MN/s',
        'Depth 18',
      ],
    );
    expect(engineStatusChoices('Stockfish 19', null), ['Stockfish 19']);
  });
}
