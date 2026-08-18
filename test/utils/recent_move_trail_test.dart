import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';

/// The Chessable-style recent-move trail: after each move the from/to squares
/// of the last two half-moves stay marked, and the oldest pair drops off as
/// new moves come in.
void main() {
  group('recentMoveTrailSquares', () {
    test('empty line yields no squares', () {
      expect(recentMoveTrailSquares(Chess.initial, const []), isEmpty);
    });

    test('single move marks its from/to squares', () {
      expect(recentMoveTrailSquares(Chess.initial, const ['e4']), {'e2', 'e4'});
    });

    test('two moves mark both pairs', () {
      expect(recentMoveTrailSquares(Chess.initial, const ['e4', 'e5']), {
        'e2',
        'e4',
        'e7',
        'e5',
      });
    });

    test('third move drops the first pair (Chessable rolling window)', () {
      expect(recentMoveTrailSquares(Chess.initial, const ['e4', 'e5', 'Nf3']), {
        'e7',
        'e5',
        'g1',
        'f3',
      });
    });

    test('castling marks the king landing square, not the rook square', () {
      const sans = ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5', 'O-O'];
      expect(recentMoveTrailSquares(Chess.initial, sans), {
        'f8',
        'c5',
        'e1',
        'g1',
      });
    });

    test('consecutive captures on one square dedupe into the set', () {
      const sans = ['e4', 'd5', 'exd5', 'Qxd5'];
      expect(recentMoveTrailSquares(Chess.initial, sans), {'e4', 'd5', 'd8'});
    });

    test('null-move tokens pass the turn without marking squares', () {
      // `--` from the start is White passing, so e4 is no longer legal.
      expect(
        recentMoveTrailSquares(Chess.initial, const ['--', 'e4']),
        isEmpty,
      );
      expect(recentMoveTrailSquares(Chess.initial, const ['d4', '--', 'Nf3']), {
        'd2',
        'd4',
        'g1',
        'f3',
      });
      expect(
        recentMoveTrailSquares(Chess.initial, const ['e4', 'Qxh8', 'e5']),
        {'e2', 'e4'},
      );
    });

    test('lastN of 1 keeps only the newest move', () {
      expect(
        recentMoveTrailSquares(Chess.initial, const ['e4', 'e5'], lastN: 1),
        {'e7', 'e5'},
      );
    });
  });
}
