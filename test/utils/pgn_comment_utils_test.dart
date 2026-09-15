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

  group('token upserts', () {
    test('eval goes in front of the prose, the rest go after it', () {
      expect(setEvalInComment('Solid.', '0.31'), '[%eval 0.31] Solid.');
      expect(setMaiaInComment('Solid.', 0.5), 'Solid. [%maia 0.500]');
      expect(
        setMaiaTopInComment('Solid.', 'Nf3', 0.45),
        'Solid. [%maiatop Nf3,0.450]',
      );
      expect(setPvInComment('Solid.', ['e4', 'e5']), 'Solid. [%pv e4,e5]');
    });

    test('replace an existing token in place', () {
      expect(
        setEvalInComment('a [%eval 0.31] b', '#3,20'),
        'a [%eval #3,20] b',
      );
      expect(setMaiaInComment('[%maia 0.100] b', 0.2), '[%maia 0.200] b');
      expect(setPvInComment('x [%bestline e4,e5] y', ['d4']), 'x [%pv d4] y');
    });

    test('an empty comment becomes the bare token', () {
      expect(setEvalInComment('   ', '0.00'), '[%eval 0.00]');
      expect(setPvInComment('', const []), '');
    });
  });

  group('display filtering', () {
    test('strips every machine token the app or Lichess writes', () {
      const comment =
          '[%eval 0.31,18] [%clk 0:02:44] [%maia 0.1] [%maiaProbability 0.4] '
          '[%humanFrequency 0.2] [%cumProb 12.5%] [%importance 0.8] '
          '[%pv e4,e5] [%transposes Nf3 d5] [%maiatop Nf3,0.450] '
          '[%cal Gd4e5] [%csl Rd4] Prose stays.';
      expect(filterDisplayComment(comment), 'Prose stays.');
      expect(stripEngineTokens(comment), 'Prose stays.');
    });

    test('drops cutechess readouts and analysis boilerplate', () {
      expect(filterDisplayComment('+0.31/24 2.001s'), '');
      expect(filterDisplayComment('book 0.010s'), '');
      expect(
        filterDisplayComment('Mistake. Nf3 was best. (0.3 → -1.2) Careful.'),
        'Careful.',
      );
    });

    test('keeps double spaces only when told to', () {
      const book = 'Or  40.cxb5  c4!-+  , winning.';
      expect(stripEngineTokens('[%eval 0.1] $book'), book);
      expect(filterDisplayComment(book), 'Or 40.cxb5 c4!-+ , winning.');
    });
  });
}
