import 'package:chess_auto_prep/features/games/models/recent_game.dart';
import 'package:chess_auto_prep/features/games/services/game_moves.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractMainlineSans', () {
    test('plain movetext with numbers and result', () {
      expect(extractMainlineSans('[Event "x"]\n\n1. e4 e5 2. Nf3 Nc6 1-0'), [
        'e4',
        'e5',
        'Nf3',
        'Nc6',
      ]);
    });

    test('strips clock/eval comments and NAGs', () {
      const pgn =
          '1. e4 { [%clk 0:03:00] } 1... c5 { [%eval 0.3] } 2. Nf3 \$2 d6 *';
      expect(extractMainlineSans(pgn), ['e4', 'c5', 'Nf3', 'd6']);
    });

    test('skips nested variations entirely', () {
      const pgn = '1. d4 d5 (1... Nf6 2. c4 (2. Bg5)) 2. c4 e6 *';
      expect(extractMainlineSans(pgn), ['d4', 'd5', 'c4', 'e6']);
    });

    test('handles glued move numbers and black continuations', () {
      expect(extractMainlineSans('1.e4 e5 2.Nf3 2...Nc6 *'), [
        'e4',
        'e5',
        'Nf3',
        'Nc6',
      ]);
    });

    test('keeps check and mate suffixes on the SAN', () {
      expect(extractMainlineSans('1. e4 f6 2. Qh5+ g6 3. Qxg6#'), [
        'e4',
        'f6',
        'Qh5+',
        'g6',
        'Qxg6#',
      ]);
    });
  });

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
