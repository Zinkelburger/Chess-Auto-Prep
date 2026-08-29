import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// The FEN readers no longer allocate a field list; these pin the cases
/// where a hand-rolled scan could drift from the `split(' ')` semantics the
/// rest of the suite assumes — doubled spaces, trailing spaces, and fields
/// that are longer or shorter than expected.
void main() {
  const standard = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  group('isWhiteToMove', () {
    test('matches split semantics on doubled and trailing spaces', () {
      expect(isWhiteToMove('board  w KQkq - 0 1'), isFalse); // empty field 2
      expect(isWhiteToMove('board w  KQkq - 0 1'), isTrue);
      expect(isWhiteToMove('board w'), isTrue);
      expect(isWhiteToMove('board w '), isTrue);
      expect(isWhiteToMove('board ww'), isFalse);
      expect(isWhiteToMove('board '), isFalse);
      expect(isWhiteToMove('w'), isFalse);
      expect(isWhiteToMove(''), isFalse);
    });
  });

  group('fullMoveNumber', () {
    test('matches split semantics', () {
      expect(fullMoveNumber(standard), 1);
      expect(fullMoveNumber('a b c d e 42'), 42);
      expect(fullMoveNumber('a b c d e 42 extra'), 42);
      expect(fullMoveNumber('a b c d e'), 1);
      expect(fullMoveNumber('a b c d e x'), 1);
      // A doubled space is an empty field, so 42 is the sixth field here…
      expect(fullMoveNumber('a  b c d 42'), 42);
      // …and here the sixth field is 'e'.
      expect(fullMoveNumber('a  b c d e 42'), 1);
    });
  });

  group('expandFen', () {
    test('counts fields the way split does', () {
      expect(expandFen('a b c d'), 'a b c d 0 1');
      expect(expandFen('a b c d 5'), 'a b c d 5 1');
      expect(expandFen('a b c d 5 9'), 'a b c d 5 9');
      expect(expandFen('a b c'), 'a b c');
      // Five tokens with a doubled space count as six fields.
      expect(expandFen('a  b c d 5'), 'a  b c d 5');
    });
  });

  group('normalizeFen', () {
    test('truncates at the fourth space only', () {
      expect(
        normalizeFen(standard),
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -',
      );
      expect(normalizeFen('a b c d'), 'a b c d');
      expect(normalizeFen('a b c d '), 'a b c d');
      expect(normalizeFen('a  b c d e'), 'a  b c');
    });
  });
}
