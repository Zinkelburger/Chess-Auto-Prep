import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/game_analysis_controller.dart'
    show cpToWinningChance;
import 'package:chess_auto_prep/utils/ease_utils.dart';
import 'package:chess_auto_prep/utils/eval_constants.dart';

void main() {
  group('winningChanceFromCp', () {
    test('zero cp is a dead-even chance', () {
      expect(winningChanceFromCp(0), closeTo(0.0, 1e-12));
    });

    test('matches the unclamped Lichess logistic inside the clamp window', () {
      for (final cp in [-1000, -300, -1, 1, 250, 999, 1000]) {
        final expected = 2.0 / (1.0 + math.exp(-kWinProbK * cp)) - 1.0;
        expect(
          winningChanceFromCp(cp),
          closeTo(expected, 1e-12),
          reason: 'cp=$cp',
        );
      }
    });

    test('clamps beyond ±1000 cp (mate-ish scores stay near ±0.95)', () {
      expect(winningChanceFromCp(1500), winningChanceFromCp(1000));
      expect(winningChanceFromCp(9997), winningChanceFromCp(1000));
      expect(winningChanceFromCp(-5000), winningChanceFromCp(-1000));
      // The clamp keeps the value visibly below full saturation…
      expect(winningChanceFromCp(9999), lessThan(0.98));
      // …while scoreToQ (unclamped curve) saturates to 1.0 at mate scores.
      expect(scoreToQ(9999), 1.0);
    });

    test('is antisymmetric', () {
      for (final cp in [50, 400, 1000, 3000]) {
        expect(
          winningChanceFromCp(-cp),
          closeTo(-winningChanceFromCp(cp), 1e-12),
        );
      }
    });
  });

  group('cpToWinningChance (game analysis wrapper)', () {
    test('delegates cp scores to the shared clamped curve', () {
      expect(cpToWinningChance(250, null), winningChanceFromCp(250));
      expect(cpToWinningChance(-4000, null), winningChanceFromCp(-1000));
    });

    test('mate scores map to pseudo-cp then clamp', () {
      // mate 3 → kMateCpBase - 3 = 9997 → clamped to 1000.
      expect(cpToWinningChance(null, 3), winningChanceFromCp(1000));
      expect(cpToWinningChance(null, -3), winningChanceFromCp(-1000));
      // Mate takes precedence over cp.
      expect(cpToWinningChance(0, 3), winningChanceFromCp(1000));
    });

    test('null scores are treated as 0 cp', () {
      expect(cpToWinningChance(null, null), 0.0);
    });
  });
}
