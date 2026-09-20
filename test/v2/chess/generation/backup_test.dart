import 'package:chess_auto_prep/v2/chess/generation/backup.dart';
import 'package:flutter_test/flutter_test.dart';

/// A node the search has not looked below: the engine's guess, and the whole
/// interval still open under it.
Valuation frontier(double value) => Valuation.provisional(value);

void main() {
  group('our turn', () {
    test('takes the best value', () {
      final node = maxOver([
        const Valuation.exact(0.4),
        const Valuation.exact(0.7),
        const Valuation.exact(0.1),
      ]);
      expect(node.value, 0.7);
      expect(node.isExact, isTrue);
    });

    test('an exact child floors the node and a frontier one opens it', () {
      // We already have the 0.7 in hand, so the answer cannot come out
      // worse; expanding the sibling could still find something better.
      final node = maxOver([const Valuation.exact(0.7), frontier(0.4)]);
      expect(node.value, 0.7);
      expect(node.lower, 0.7);
      expect(node.upper, 1);
      expect(node.isExact, isFalse);
    });

    test('a frontier child with a better guess still leads on that guess', () {
      final node = maxOver([const Valuation.exact(0.3), frontier(0.8)]);
      expect(node.value, 0.8);
      expect(node.lower, 0.3);
      expect(node.upper, 1);
    });

    test('the bounds are the best of every child, not the chosen one', () {
      // The move we would play is settled at 0.6; a sibling we have only
      // narrowed to [0.2, 0.9] could still overtake it, so the node's upper
      // bound is that sibling's, not the leader's.
      final node = maxOver([
        const Valuation.exact(0.6),
        const Valuation(value: 0.5, lower: 0.2, upper: 0.9),
      ]);
      expect(node.value, 0.6);
      expect(node.lower, 0.6);
      expect(node.upper, 0.9);
    });

    test('a single child is the node', () {
      final node = maxOver([
        const Valuation(value: 0.3, lower: 0.2, upper: 0.4),
      ]);
      expect((node.value, node.lower, node.upper), (0.3, 0.2, 0.4));
    });
  });

  group("the opponent's turn", () {
    test('averages the replies by how likely they are', () {
      final node = weightedSum([
        (0.75, const Valuation.exact(0.4)),
        (0.25, const Valuation.exact(0.8)),
      ]);
      expect(node.value, closeTo(0.5, 1e-12));
      expect(node.isExact, isTrue);
    });

    test('a finished reply narrows the node before the last one lands', () {
      // Three quarters of the answer is settled at 0.4, so the node can no
      // longer be worse than 0.3 or better than 0.55, however the remaining
      // quarter turns out.
      final node = weightedSum([
        (0.75, const Valuation.exact(0.4)),
        (0.25, frontier(0.8)),
      ]);
      expect(node.value, closeTo(0.5, 1e-12));
      expect(node.lower, closeTo(0.3, 1e-12));
      expect(node.upper, closeTo(0.55, 1e-12));
    });

    test('an unlikely reply moves the bounds only a little', () {
      final node = weightedSum([
        (0.99, const Valuation.exact(0.5)),
        (0.01, frontier(0.5)),
      ]);
      expect(node.lower, closeTo(0.495, 1e-12));
      expect(node.upper, closeTo(0.505, 1e-12));
    });

    test('replies that do not share one whole move are a bug, not a clamp', () {
      expect(
        () => weightedSum([
          (0.75, const Valuation.exact(1)),
          (0.75, const Valuation.exact(1)),
        ]),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
