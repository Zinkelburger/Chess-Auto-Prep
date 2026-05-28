import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/features/traps/widgets/trap_navigation_buttons.dart';

TrapLineInfo _trap(List<String> moves) {
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
    trickSurplus: 0.08,
    expectimaxValue: 0.59,
    wpEval: 0.51,
  );
}

void main() {
  group('TrapNavigationButtons.findCurrentTrapIndex', () {
    test('returns -1 before first trap', () {
      final traps = [
        _trap(['e4', 'c6', 'd4']),
        _trap(['e4', 'c6', 'd4', 'd5', 'e5']),
      ];

      expect(TrapNavigationButtons.findCurrentTrapIndex(traps, 0), -1);
      expect(TrapNavigationButtons.findCurrentTrapIndex(traps, 1), -1);
    });

    test('returns trap index at or before current ply', () {
      final traps = [
        _trap(['e4', 'c6', 'd4']),
        _trap(['e4', 'c6', 'd4', 'd5', 'e5']),
      ];

      expect(TrapNavigationButtons.findCurrentTrapIndex(traps, 2), 0);
      expect(TrapNavigationButtons.findCurrentTrapIndex(traps, 4), 1);
      expect(TrapNavigationButtons.findCurrentTrapIndex(traps, 99), 1);
    });

    test('returns empty for no traps', () {
      expect(TrapNavigationButtons.findCurrentTrapIndex([], 5), -1);
    });
  });
}
