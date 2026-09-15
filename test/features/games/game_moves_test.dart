import 'package:chess_auto_prep/features/games/models/recent_game.dart';
import 'package:chess_auto_prep/features/games/services/game_moves.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeSan', () {
    test('strips only trailing check/mate marks', () {
      expect(normalizeSan('Qh5+'), 'Qh5');
      expect(normalizeSan('Qxg6#'), 'Qxg6');
      expect(normalizeSan('O-O-O'), 'O-O-O');
      expect(normalizeSan('e8=Q+'), 'e8=Q');
    });
  });

  group('formatTimeControl', () {
    test('minutes plus increment', () {
      expect(formatTimeControl('180+2'), '3+2');
      expect(formatTimeControl('600'), '10+0');
      expect(formatTimeControl('60+1'), '1+1');
    });

    test('sub-minute bases use fractions', () {
      expect(formatTimeControl('30'), '½+0');
      expect(formatTimeControl('15+1'), '¼+1');
    });

    test('correspondence and unknown forms', () {
      expect(formatTimeControl('-'), '∞');
      expect(formatTimeControl('1/259200'), 'corr');
      expect(formatTimeControl(null), '?');
    });
  });
}
