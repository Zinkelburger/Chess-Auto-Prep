import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart';

void main() {
  group('primaryQualityNag', () {
    test('returns null for null / empty / non-quality NAGs', () {
      expect(primaryQualityNag(null), isNull);
      expect(primaryQualityNag(const []), isNull);
      expect(primaryQualityNag(const [10, 22]), isNull); // outside 1..6
    });

    test('returns the first quality NAG in list order', () {
      expect(primaryQualityNag(const [3]), 3);
      expect(primaryQualityNag(const [22, 5]), 5); // skips non-quality
      expect(primaryQualityNag(const [1, 4]), 1); // first wins
    });
  });

  group('qualityNagSuffix', () {
    test('is empty when no quality NAG is present', () {
      expect(qualityNagSuffix(null), '');
      expect(qualityNagSuffix(const []), '');
      expect(qualityNagSuffix(const [22]), '');
    });

    test('maps quality NAG ids to their glyph symbols', () {
      expect(qualityNagSuffix(const [3]), '!!');
      expect(qualityNagSuffix(const [5]), '!?');
      expect(qualityNagSuffix(const [6]), '?!');
      // Non-quality NAGs are filtered out of the suffix.
      expect(qualityNagSuffix(const [22, 4]), '??');
    });
  });

  group('toggleQualityNag', () {
    test('adds a quality NAG when none is set', () {
      expect(toggleQualityNag(null, 1), const [1]);
      expect(toggleQualityNag(const [], 3), const [3]);
    });

    test('removes the quality NAG that is already present', () {
      expect(toggleQualityNag(const [1], 1), const <int>[]);
    });

    test('is mutually exclusive: setting one clears the other quality NAG', () {
      // Was "?" (2); toggling "!!" (3) replaces it.
      expect(toggleQualityNag(const [2], 3), const [3]);
    });

    test('preserves non-quality NAGs while toggling a quality NAG', () {
      // 22 is a non-quality NAG and must survive both add and clear.
      expect(toggleQualityNag(const [22], 1), const [1, 22]);
      expect(toggleQualityNag(const [1, 22], 5), const [5, 22]);
      expect(toggleQualityNag(const [1, 22], 1), const [22]);
    });

    test('out-of-range ids are never added as quality glyphs', () {
      // Callers only ever pass ids 1..6 (from kMoveNags). An out-of-range id
      // clears any quality glyph (the mutual-exclusion step) but adds nothing.
      expect(toggleQualityNag(const [1], 10), const <int>[]);
      // Non-quality NAGs still survive.
      expect(toggleQualityNag(const [1, 22], 10), const [22]);
    });
  });
}
