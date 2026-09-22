import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/maia/maia_mirror.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'flips the ranks, the colours, the side, the rights and the ep square',
    () {
      const fen = Fen(
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
      );
      expect(
        mirrorFen(fen).value,
        'rnbqkbnr/pppp1ppp/8/4p3/8/8/PPPPPPPP/RNBQKBNR w KQkq e6 0 1',
      );
    },
  );

  test('gives one side its own rights back', () {
    const fen = Fen('r3k2r/8/8/8/8/8/8/R3K2R b Kq - 4 12');
    expect(mirrorFen(fen).value, 'r3k2r/8/8/8/8/8/8/R3K2R w Qk - 4 12');
  });

  test('mirroring twice is the position you started with', () {
    const fen = Fen(
      'r1bq1rk1/pp2ppbp/2np1np1/8/2BNP3/2N1B3/PPP2PPP/R2Q1RK1 w - - 3 9',
    );
    expect(mirrorFen(mirrorFen(fen)).value, fen.value);
  });

  test('a position with no rights and no ep square keeps its dashes', () {
    const fen = Fen('8/8/8/8/P7/3k4/8/4K3 b - - 0 2');
    expect(mirrorFen(fen).value, '4k3/8/3K4/p7/8/8/8/8 w - - 0 2');
  });

  test('a four-field FEN comes back with the counters it needs', () {
    const fen = Fen('4k3/8/8/8/8/8/8/4K3 b - -');
    expect(mirrorFen(fen).value, '4k3/8/8/8/8/8/8/4K3 w - - 0 1');
  });

  test('a move on the mirrored board', () {
    expect(mirrorUci('e7e5'), 'e2e4');
    expect(mirrorUci('a7a8q'), 'a2a1q');
    expect(mirrorUci('e8g8'), 'e1g1');
    expect(mirrorUci(mirrorUci('b1c3')), 'b1c3');
  });
}
