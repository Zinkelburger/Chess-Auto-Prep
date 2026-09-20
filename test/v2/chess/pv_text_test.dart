import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pv_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const after1e4 = Fen(
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
  );

  test('numbers a line from either side', () {
    expect(pvText(Fen.initial, ['e2e4', 'e7e5', 'g1f3']), '1. e4 e5 2. Nf3');
    expect(pvText(after1e4, ['c7c5', 'g1f3', 'd7d6']), '1... c5 2. Nf3 d6');
  });

  test('stops at a move that is not legal here', () {
    expect(pvText(Fen.initial, ['e2e4', 'e2e4', 'd7d5']), '1. e4');
    expect(pvText(Fen.initial, ['zz']), '');
  });

  test('uses SAN detail: captures, castling, checks', () {
    const italian = Fen(
      'r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4',
    );
    expect(
      pvText(italian, ['e1g1', 'g8f6', 'f3e5', 'c6e5']),
      '4. O-O Nf6 5. Nxe5 Nxe5',
    );
  });
}
