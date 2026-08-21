import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';

/// Every reader in `fen_utils` is total: none throws on a short, empty or
/// malformed FEN, and all three fall back to the standard start's values so
/// two of them can never disagree. Hand-rolled `split(' ')[1]` reads are what
/// these replace, and those threw `RangeError`.
void main() {
  const afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
  const afterE4E5 =
      'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2';

  group('isWhiteToMove', () {
    test('reads the active-colour field', () {
      expect(isWhiteToMove(kStandardStartFen), isTrue);
      expect(isWhiteToMove(afterE4), isFalse);
      expect(isWhiteToMove(afterE4E5), isTrue);
    });

    test('only an explicit w is White — the pinned adversarial contract', () {
      // test/services/fen_move_validation_test.dart owns this fallback; it is
      // deliberately strict so a garbled field cannot read as a real side.
      expect(isWhiteToMove(''), isFalse);
      expect(
        isWhiteToMove('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR'),
        isFalse,
      );
      expect(isWhiteToMove('board x KQkq - 0 1'), isFalse);
      expect(isWhiteToMove('board b'), isFalse);
    });
  });

  group('fullMoveNumber', () {
    test('reads the sixth field', () {
      expect(fullMoveNumber(kStandardStartFen), 1);
      expect(fullMoveNumber(afterE4E5), 2);
      expect(fullMoveNumber('board w KQkq - 3 17'), 17);
    });

    test('falls back to 1 on a short or unparseable FEN', () {
      expect(fullMoveNumber(''), 1);
      expect(fullMoveNumber('board w KQkq -'), 1);
      expect(fullMoveNumber('board w KQkq - 0 zz'), 1);
    });
  });

  group('plyFromFen', () {
    test('counts from move 1 with White to move', () {
      expect(plyFromFen(kStandardStartFen), 0);
      expect(plyFromFen(afterE4), 1);
      expect(plyFromFen(afterE4E5), 2);
      expect(plyFromFen('board b KQkq - 0 2'), 3);
    });

    test('never throws on a short or empty FEN', () {
      for (final fen in ['', 'board', 'board w', 'board b', '   ']) {
        expect(() => plyFromFen(fen), returnsNormally, reason: fen);
      }
      expect(plyFromFen('board w'), 0);
    });

    test('agrees with the two fields it is derived from', () {
      for (final fen in [
        kStandardStartFen,
        afterE4,
        afterE4E5,
        'board b KQkq - 0 9',
        'board w - - 0 40',
        'board q KQkq - 0 3',
        '',
        'board',
      ]) {
        final ply = plyFromFen(fen);
        expect(
          ply.isEven,
          isWhiteToMove(fen),
          reason: 'even plies are White to move, for "$fen"',
        );
        expect(
          ply ~/ 2 + 1,
          fullMoveNumber(fen),
          reason:
              'ply and full-move number must describe the same position, '
              'for "$fen"',
        );
      }
    });
  });

  group('normalizeFen', () {
    test('keeps the first four fields and drops the clocks', () {
      expect(
        normalizeFen(afterE4E5),
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6',
      );
    });

    test('leaves an already-short FEN alone', () {
      expect(normalizeFen('board w KQkq -'), 'board w KQkq -');
      expect(normalizeFen('board'), 'board');
      expect(normalizeFen(''), '');
    });

    test('two FENs differing only in clocks normalise equal', () {
      expect(
        normalizeFen('board w KQkq - 0 1'),
        normalizeFen('board w KQkq - 39 84'),
      );
    });
  });

  group('expandFen', () {
    test('pads a short FEN to six fields', () {
      expect(expandFen('board w KQkq -'), 'board w KQkq - 0 1');
      expect(expandFen('board w KQkq - 3'), 'board w KQkq - 3 1');
    });

    test('leaves a complete FEN alone', () {
      expect(expandFen(kStandardStartFen), kStandardStartFen);
    });
  });
}
