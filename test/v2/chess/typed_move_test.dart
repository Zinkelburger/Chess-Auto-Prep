import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/typed_move.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const start = Fen.initial;

  /// White to move with a pawn and a bishop both able to take on c4, a
  /// pawn on e7 about to promote, and castling either way.
  const busy = Fen('8/1k2P3/8/8/2p5/1P1B4/8/R3K2R w KQ - 0 1');

  test('SAN, as typed or as printed', () {
    expect(typedMove(start, 'Nf3'), 'g1f3');
    expect(typedMove(start, 'e4'), 'e2e4');
    expect(typedMove(start, 'Nf3+'), 'g1f3');
    expect(typedMove(start, 'nf3'), 'g1f3', reason: 'case is only a hint');
  });

  test('UCI', () {
    expect(typedMove(start, 'g1f3'), 'g1f3');
    expect(typedMove(start, 'E2E4'), 'e2e4');
  });

  test('capture marks and castling spellings are optional', () {
    expect(typedMove(busy, 'Bxc4'), 'd3c4');
    expect(typedMove(busy, 'Bc4'), 'd3c4');
    expect(typedMove(busy, 'bxc4'), 'b3c4');
    expect(typedMove(busy, 'O-O'), 'e1g1');
    expect(typedMove(busy, '0-0-0'), 'e1c1');
    expect(typedMove(busy, 'e1g1'), 'e1g1');
  });

  test('words that name two moves wait for more', () {
    // Lower case, `bc4` is the pawn's capture and the bishop's move both.
    expect(typedMove(busy, 'bc4'), 'b3c4', reason: 'the pawn, as spelled');
    expect(typedMove(busy, 'e8'), isNull, reason: 'which piece?');
    expect(typedMove(busy, 'e8=Q'), 'e7e8q');
    expect(typedMove(busy, 'e8n'), 'e7e8n');
    expect(typedMove(busy, 'e7e8q'), 'e7e8q');
  });

  test('nothing, or no legal move, is null', () {
    expect(typedMove(start, ''), isNull);
    expect(typedMove(start, 'N'), isNull);
    expect(typedMove(start, 'e5'), isNull);
    expect(typedMove(start, 'Ke2'), isNull);
    expect(typedMove(const Fen('not a fen'), 'e4'), isNull);
  });
}
