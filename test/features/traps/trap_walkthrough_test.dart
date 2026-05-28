import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/features/traps/widgets/trap_walkthrough.dart';

TrapLineInfo _trap(List<String> moves, {double surplus = 0.1, String? fen}) {
  return TrapLineInfo(
    movesSan: moves,
    trapScore: 0.5,
    popularProb: 0.4,
    popularMove: 'Nd7',
    bestMove: 'b4',
    popularEvalCp: 252,
    bestEvalCp: 10,
    evalDiffCp: 200,
    cumulativeProb: 0.01,
    trickSurplus: surplus,
    expectimaxValue: 0.59,
    wpEval: 0.51,
    fen: fen,
  );
}

void main() {
  group('TrapWalkthrough', () {
    test('sortedTraps orders by trick surplus descending', () {
      final traps = [
        _trap(['e4'], surplus: 0.05),
        _trap(['d4'], surplus: 0.20),
        _trap(['c4'], surplus: 0.12),
      ];

      final sorted = TrapWalkthrough.sortedTraps(traps);
      expect(sorted.map((t) => t.movesSan.first).toList(),
          ['d4', 'c4', 'e4']);
    });

    test('indexOfTrap finds trap by moves', () {
      final a = _trap(['e4', 'e5'], fen: 'fen-a');
      final b = _trap(['d4', 'd5'], fen: 'fen-b');
      final sorted = TrapWalkthrough.sortedTraps([a, b]);

      expect(TrapWalkthrough.indexOfTrap(sorted, b), 1);
      expect(TrapWalkthrough.sameTrap(a, a), isTrue);
      expect(TrapWalkthrough.sameTrap(a, b), isFalse);
    });

    test('TrapIndexService.allTraps exposes load order', () {
      final index = TrapIndexService([
        _trap(['e4'], fen: 'f1'),
        _trap(['d4'], fen: 'f2'),
      ]);
      expect(index.allTraps.length, 2);
      expect(index.allTraps.first.movesSan, ['e4']);
    });
  });
}
