import 'package:chess_auto_prep/features/bughouse/models/bughouse_history.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// [BughouseHistory.play]: the one path a move takes onto a line.
void main() {
  const e4 = NormalMove(from: Square.e2, to: Square.e4);
  const d5 = NormalMove(from: Square.d7, to: Square.d5);
  const exd5 = NormalMove(from: Square.e4, to: Square.d5);

  test('a legal move is recorded with its SAN and advances the cursor', () {
    final line = BughouseHistory(BughouseState.initial());
    final ply = line.play(BughouseBoard.a, e4)!;
    expect(ply.san, 'e4');
    expect(ply.board, BughouseBoard.a);
    expect(ply.before.boardA.turn, Side.white);
    expect(ply.after.boardA.turn, Side.black);
    expect(line.length, 1);
    expect(line.cursor, 1);
    expect(line.current.boardA.turn, Side.black);
  });

  test('an illegal move records nothing', () {
    final line = BughouseHistory(BughouseState.initial());
    expect(line.play(BughouseBoard.b, d5), isNull);
    expect(line.isEmpty, isTrue);
  });

  test('a capture crosses to the partner board', () {
    final line = BughouseHistory(BughouseState.initial());
    line.play(BughouseBoard.a, e4);
    line.play(BughouseBoard.a, d5);
    final ply = line.play(BughouseBoard.a, exd5)!;
    expect(ply.san, 'exd5');
    expect(ply.after.boardA.pockets?.of(Side.white, Role.pawn) ?? 0, 0);
    expect(ply.after.boardB.pockets?.of(Side.black, Role.pawn), 1);
  });

  test('playing from a rewound position truncates the line', () {
    final line = BughouseHistory(BughouseState.initial());
    line.play(BughouseBoard.a, e4);
    line.play(BughouseBoard.a, d5);
    line.toStart();
    line.play(BughouseBoard.b, e4);
    expect(line.plies.map((p) => p.board), [BughouseBoard.b]);
    expect(line.cursor, 1);
  });
}
