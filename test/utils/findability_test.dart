import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/utils/findability.dart';

void main() {
  group('pRefForElo', () {
    test('clamps below and above the anchor range', () {
      expect(pRefForElo(300), 0.12);
      expect(pRefForElo(600), 0.12);
      expect(pRefForElo(2600), 0.005);
      expect(pRefForElo(3000), 0.005);
    });

    test('returns anchor values exactly', () {
      expect(pRefForElo(1000), 0.08);
      expect(pRefForElo(1400), 0.05);
      expect(pRefForElo(1800), 0.03);
      expect(pRefForElo(2200), 0.015);
    });

    test('interpolates linearly between anchors', () {
      // Midpoint of (1400, 0.05) and (1800, 0.03).
      expect(pRefForElo(1600), closeTo(0.04, 1e-12));
      // Quarter of the way from (2200, 0.015) to (2600, 0.005).
      expect(pRefForElo(2300), closeTo(0.0125, 1e-12));
    });
  });

  group('findabilityFactor', () {
    test('demote-only: caps at 1.0 above the bar', () {
      expect(findabilityFactor(0.5, 0.05), 1.0);
      expect(findabilityFactor(0.05, 0.05), 1.0);
    });

    test('proportional discount below the bar', () {
      expect(findabilityFactor(0.01, 0.05), closeTo(0.2, 1e-12));
      expect(findabilityFactor(0.0, 0.05), 0.0);
    });

    test('missing Maia data (negative prob) never distorts', () {
      expect(findabilityFactor(-1.0, 0.05), 1.0);
    });

    test('non-positive pRef disables the discount', () {
      expect(findabilityFactor(0.01, 0.0), 1.0);
      expect(findabilityFactor(0.01, -1.0), 1.0);
    });
  });
}
