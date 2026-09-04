/// Comment-block handling in `pgn_comment_utils.dart`.
///
/// Lived in the NAG suite until the NAG table moved to its own module; it was
/// never about NAGs.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/utils/pgn_comment_utils.dart';

void main() {
  group('joinComments', () {
    test('is empty for null / empty / whitespace-only blocks', () {
      expect(joinComments(null), '');
      expect(joinComments(const []), '');
      expect(joinComments(const ['', '   ']), '');
    });

    test('keeps every block, not just the first', () {
      expect(
        joinComments(const ['A sharp line.', '[%cal Rf3g5]']),
        'A sharp line. [%cal Rf3g5]',
      );
    });
  });
}
