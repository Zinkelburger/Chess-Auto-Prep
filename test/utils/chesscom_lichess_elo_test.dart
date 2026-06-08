import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/utils/chesscom_lichess_elo.dart';

void main() {
  group('chessComBlitzToLichessBlitz', () {
    test('returns exact table anchors', () {
      expect(chessComBlitzToLichessBlitz(800), 1200);
      expect(chessComBlitzToLichessBlitz(1000), 1420);
      expect(chessComBlitzToLichessBlitz(1150), 1525);
      expect(chessComBlitzToLichessBlitz(2000), 2100);
      expect(chessComBlitzToLichessBlitz(3000), 2850);
    });

    test('interpolates between anchors', () {
      expect(chessComBlitzToLichessBlitz(1175), 1545);
      expect(chessComBlitzToLichessBlitz(2050), 2135);
    });

    test('clamps below and above table', () {
      expect(chessComBlitzToLichessBlitz(400), 1030);
      expect(chessComBlitzToLichessBlitz(3100), 2850);
    });
  });
}
