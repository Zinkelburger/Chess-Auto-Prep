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

  test('each move knows its label, its UCI and the position after it', () {
    final moves = pvMoves(after1e4, ['c7c5', 'g1f3']);
    expect(moves.map((m) => m.label), ['1...', '2.']);
    expect(moves.map((m) => m.san), ['c5', 'Nf3']);
    expect(moves.map((m) => m.uci), ['c7c5', 'g1f3']);
    expect(
      moves.first.after.value,
      'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
    );
    expect(moves.last.after.whiteToMove, isFalse);
    expect(moves.last.text, '2. Nf3');
    expect(pvMoves(Fen.initial, ['e2e4', 'e7e5']).last.text, 'e5');
  });

  test('stops at a move that is not legal here', () {
    expect(pvText(Fen.initial, ['e2e4', 'e2e4', 'd7d5']), '1. e4');
    expect(pvText(Fen.initial, ['zz']), '');
  });

  test('a FEN that is not a position has no line', () {
    expect(pvText(const Fen('not a position'), ['e2e4']), '');
    // Enough fields to parse, but no kings: a setup, not a chess position.
    expect(pvText(const Fen('8/8/8/8/8/8/8/8 w - - 0 1'), ['e2e4']), '');
    // A board the parser answers with an error rather than an exception.
    expect(pvText(const Fen('8/8/8/8/8/8/8/.N w - - 0 1'), ['e2e4']), '');
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
