// Dirichlet λ-smoothing of opponent move frequencies with a Maia prior:
//   p = (count + λ·maiaP) / (N + λ)
// Large N → data dominates; N = 0 → pure Maia; λ = 0 → raw frequencies.

import 'package:chess_auto_prep/services/generation/opponent_prior.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('smoothOpponentMoves', () {
    test('λ = 0 reduces to raw frequencies', () {
      final out = smoothOpponentMoves(
        observed: const [
          ObservedMove(uci: 'e7e5', san: 'e5', games: 75),
          ObservedMove(uci: 'c7c5', san: 'c5', games: 25),
        ],
        totalGames: 100,
        maiaPolicy: const {},
        priorGames: 0,
      );
      expect(out.length, 2);
      expect(out[0].uci, 'e7e5');
      expect(out[0].probability, closeTo(0.75, 1e-12));
      expect(out[1].probability, closeTo(0.25, 1e-12));
    });

    test('zero games degrades to pure Maia policy', () {
      final out = smoothOpponentMoves(
        observed: const [],
        totalGames: 0,
        maiaPolicy: const {'e7e5': 0.6, 'c7c5': 0.3},
        priorGames: 30,
      );
      expect(out.length, 2);
      expect(out[0].uci, 'e7e5');
      expect(out[0].probability, closeTo(0.6, 1e-12));
      expect(out[1].probability, closeTo(0.3, 1e-12));
      expect(out[0].games, 0);
    });

    test('blends counts with prior at the documented formula', () {
      // N=10, λ=30: p(e5) = (7 + 30·0.5) / 40 = 0.55
      final out = smoothOpponentMoves(
        observed: const [ObservedMove(uci: 'e7e5', san: 'e5', games: 7)],
        totalGames: 10,
        maiaPolicy: const {'e7e5': 0.5, 'c7c5': 0.4},
        priorGames: 30,
      );
      final e5 = out.firstWhere((m) => m.uci == 'e7e5');
      final c5 = out.firstWhere((m) => m.uci == 'c7c5');
      expect(e5.probability, closeTo((7 + 30 * 0.5) / 40, 1e-12));
      // Maia-only move gets prior-only mass: 30·0.4 / 40 = 0.3
      expect(c5.probability, closeTo(0.3, 1e-12));
      expect(c5.san, isEmpty);
    });

    test('large N makes the prior negligible', () {
      final out = smoothOpponentMoves(
        observed: const [ObservedMove(uci: 'e7e5', san: 'e5', games: 5000)],
        totalGames: 10000,
        maiaPolicy: const {'e7e5': 0.01},
        priorGames: 30,
      );
      expect(out.first.probability, closeTo(0.5, 0.002));
    });

    test('sorts by smoothed probability descending', () {
      final out = smoothOpponentMoves(
        observed: const [
          ObservedMove(uci: 'a7a6', san: 'a6', games: 3),
          ObservedMove(uci: 'e7e5', san: 'e5', games: 4),
        ],
        totalGames: 10,
        maiaPolicy: const {'c7c5': 0.9},
        priorGames: 30,
      );
      // c5: 27/40 = 0.675 beats e5: 4/40 and a6: 3/40
      expect(out.map((m) => m.uci).toList(), ['c7c5', 'e7e5', 'a7a6']);
    });
  });

  group('smoothingWorthwhile', () {
    test('off when priorGames is zero', () {
      expect(smoothingWorthwhile(5, 0), isFalse);
    });
    test('on for sparse positions, off for well-covered ones', () {
      expect(smoothingWorthwhile(50, 30), isTrue);
      expect(smoothingWorthwhile(30 * kSmoothingSkipFactor + 1, 30), isFalse);
    });
  });
}
