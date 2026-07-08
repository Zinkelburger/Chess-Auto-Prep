import 'package:chess_auto_prep/services/generation/setup_bias.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseSetupMoves', () {
    test('splits on spaces and commas, normalizes suffixes', () {
      expect(
        parseSetupMoves('Be3 Qd2, f3  O-O-O h4 Nh3+'),
        {'Be3', 'Qd2', 'f3', 'O-O-O', 'h4', 'Nh3'},
      );
    });

    test('empty and whitespace-only input disable the bias', () {
      expect(parseSetupMoves(''), isEmpty);
      expect(parseSetupMoves('   '), isEmpty);
    });
  });

  group('normalizeSetupSan', () {
    test('strips check/mate marks and annotations', () {
      expect(normalizeSetupSan('Qd2+'), 'Qd2');
      expect(normalizeSetupSan('Nh3#'), 'Nh3');
      expect(normalizeSetupSan('h4!?'), 'h4');
      expect(normalizeSetupSan('O-O-O'), 'O-O-O');
    });
  });

  group('sanToUci', () {
    const startFen =
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

    test('converts legal SAN to UCI', () {
      expect(sanToUci(startFen, 'e4'), 'e2e4');
      expect(sanToUci(startFen, 'Nf3'), 'g1f3');
    });

    test('returns null for illegal SAN', () {
      expect(sanToUci(startFen, 'Qd2'), isNull);
      expect(sanToUci(startFen, 'O-O-O'), isNull);
    });

    test('castling uses king-destination convention', () {
      // White ready to castle long.
      const fen = 'r3kbnr/ppp2ppp/2npbq2/4p3/4P3/2NPBQ2/PPP2PPP/R3KBNR '
          'w KQkq - 0 1';
      expect(sanToUci(fen, 'O-O-O'), 'e1c1');
    });
  });
}
