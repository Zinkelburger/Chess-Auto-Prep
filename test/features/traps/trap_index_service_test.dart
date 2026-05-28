import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';

TrapLineInfo _makeTrap({
  required List<String> moves,
  double trapScore = 0.5,
  double popularProb = 0.4,
  int evalDiffCp = 200,
  double cumulativeProb = 0.01,
  double trickSurplus = 0.08,
  String? fen,
}) {
  return TrapLineInfo(
    movesSan: moves,
    trapScore: trapScore,
    popularProb: popularProb,
    popularMove: 'Nd7',
    bestMove: 'b4',
    popularEvalCp: 252,
    bestEvalCp: 10,
    evalDiffCp: evalDiffCp,
    cumulativeProb: cumulativeProb,
    trickSurplus: trickSurplus,
    expectimaxValue: 0.593,
    wpEval: 0.510,
    fen: fen,
  );
}

void main() {
  group('TrapIndexService', () {
    test('trapAtFen returns correct trap', () {
      final traps = [
        _makeTrap(
          moves: ['e4', 'c6', 'd4', 'd5', 'e5'],
          fen: 'rnbqkbnr/pp2pppp/2p5/3pP3/3P4/8/PPP2PPP/RNBQKBNR b KQkq -',
        ),
      ];

      final index = TrapIndexService(traps);
      final found = index.trapAtFen(
          'rnbqkbnr/pp2pppp/2p5/3pP3/3P4/8/PPP2PPP/RNBQKBNR b KQkq -');
      expect(found, isNotNull);
      expect(found!.movesSan.last, 'e5');
    });

    test('trapAtFen returns null for unknown FEN', () {
      final index = TrapIndexService([
        _makeTrap(moves: ['e4'], fen: 'some-fen'),
      ]);
      expect(index.trapAtFen('other-fen'), isNull);
    });

    test('trapsInLine finds prefix matches', () {
      final traps = [
        _makeTrap(moves: ['e4', 'c6', 'd4']),
        _makeTrap(moves: ['e4', 'c6', 'd4', 'd5', 'e5']),
        _makeTrap(moves: ['d4', 'Nf6']),
      ];

      final index = TrapIndexService(traps);
      final found =
          index.trapsInLine(['e4', 'c6', 'd4', 'd5', 'e5', 'Bf5']);

      expect(found.length, 2);
      expect(found.first.movesSan.length, 3);
      expect(found.last.movesSan.length, 5);
    });

    test('trapsInLine returns empty for no matches', () {
      final index = TrapIndexService([
        _makeTrap(moves: ['e4', 'e5']),
      ]);
      expect(index.trapsInLine(['d4', 'd5']), isEmpty);
    });

    test('metricsForLine computes correct stats', () {
      final traps = [
        _makeTrap(
          moves: ['e4', 'c6'],
          evalDiffCp: 100,
          cumulativeProb: 0.02,
          popularProb: 0.3,
        ),
        _makeTrap(
          moves: ['e4', 'c6', 'd4', 'd5'],
          evalDiffCp: 250,
          cumulativeProb: 0.01,
          popularProb: 0.4,
        ),
      ];

      final index = TrapIndexService(traps);
      final metrics =
          index.metricsForLine(['e4', 'c6', 'd4', 'd5', 'e5']);

      expect(metrics.count, 2);
      expect(metrics.bestEvalDiff, 250);
      expect(metrics.totalReach, closeTo(0.03, 0.001));
    });

    test('metrics computes repertoire-level stats', () {
      final traps = [
        _makeTrap(
          moves: ['e4'],
          evalDiffCp: 200,
          cumulativeProb: 0.05,
          trickSurplus: 0.12,
        ),
        _makeTrap(
          moves: ['d4'],
          evalDiffCp: 100,
          cumulativeProb: 0.03,
          trickSurplus: 0.05,
        ),
      ];

      final index = TrapIndexService(traps);
      expect(index.metrics.totalTraps, 2);
      expect(index.metrics.highQualityCount, 1);
      expect(index.metrics.avgReach, closeTo(0.04, 0.001));
    });

    test('empty traps produce empty metrics', () {
      final index = TrapIndexService([]);
      expect(index.metrics.totalTraps, 0);
      expect(index.metrics.avgReach, 0);
    });
  });
}
