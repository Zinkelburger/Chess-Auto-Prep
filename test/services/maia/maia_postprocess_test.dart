import 'dart:typed_data';

import 'package:chess_auto_prep/services/maia/maia_postprocess.dart';
import 'package:flutter_test/flutter_test.dart';

/// Vocabulary stand-in: index 0 is e2e4, 1 is d2d4, 2 is g1f3.
const _moves = ['e2e4', 'd2d4', 'g1f3'];
String _moveOf(int index) => _moves[index];

/// A stand-in mirror that tags the move, enough to see it was applied.
String _mirror(String uci) => 'm:$uci';

void main() {
  group('winProbabilityFromWdl', () {
    test('a certain win is 1.0 for White to move', () {
      expect(winProbabilityFromWdl([-50, -50, 50], isBlack: false), 1.0);
    });

    test('a draw counts half, from White\'s side either way', () {
      final white = winProbabilityFromWdl([-50, 50, -50], isBlack: false);
      final black = winProbabilityFromWdl([-50, 50, -50], isBlack: true);
      expect(white, 0.5);
      expect(black, 0.5);
    });

    test('Black to move flips the perspective', () {
      final asWhite = winProbabilityFromWdl([0, 0, 2], isBlack: false);
      final asBlack = winProbabilityFromWdl([0, 0, 2], isBlack: true);
      expect(asWhite, greaterThan(0.5));
      expect(asBlack, closeTo(1 - asWhite, 1e-4));
    });

    test('is rounded to four decimals and tolerates a short head', () {
      final p = winProbabilityFromWdl([0.1, 0.2, 0.3], isBlack: false);
      expect((p * 10000).round() / 10000, p);
      expect(winProbabilityFromWdl([0.1], isBlack: false), 0.5);
    });
  });

  group('policyFromLogits', () {
    test('softmaxes over the legal moves only, best first', () {
      final policy = policyFromLogits(
        [1.0, 3.0, 2.0],
        Float32List.fromList([1, 0, 1]),
        isBlack: false,
        moveOf: _moveOf,
        mirrorMove: _mirror,
      );
      expect(policy.keys.toList(), ['g1f3', 'e2e4']);
      expect(policy.values.reduce((a, b) => a + b), closeTo(1.0, 1e-9));
      expect(policy['g1f3']!, greaterThan(policy['e2e4']!));
    });

    test('mirrors the keys for Black', () {
      final policy = policyFromLogits(
        [0.0, 0.0, 0.0],
        Float32List.fromList([1, 1, 0]),
        isBlack: true,
        moveOf: _moveOf,
        mirrorMove: _mirror,
      );
      expect(policy.keys.toSet(), {'m:e2e4', 'm:d2d4'});
    });

    test('a legal move the network did not score gets ~0', () {
      final policy = policyFromLogits(
        [0.0],
        Float32List.fromList([1, 1, 0]),
        isBlack: false,
        moveOf: _moveOf,
        mirrorMove: _mirror,
      );
      expect(policy['e2e4'], closeTo(1.0, 1e-9));
      expect(policy['d2d4'], closeTo(0.0, 1e-9));
    });

    test('no legal moves yields an empty policy', () {
      expect(
        policyFromLogits(
          [1.0, 2.0, 3.0],
          Float32List(3),
          isBlack: false,
          moveOf: _moveOf,
          mirrorMove: _mirror,
        ),
        isEmpty,
      );
    });
  });
}
