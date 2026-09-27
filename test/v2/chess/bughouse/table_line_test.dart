import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table_line.dart';
import 'package:flutter_test/flutter_test.dart';

/// [moves] (`1e2e4 2d2d4`, board digit then UCI) played in order.
TableLine playedLine(String moves, [TableLine? from]) {
  var line = from ?? const TableLine(TablePosition.initial);
  for (final token in moves.split(' ').where((t) => t.isNotEmpty)) {
    final board = token[0] == '1' ? BoardNumber.one : BoardNumber.two;
    final position = (line.replay() as LineReplayed).position;
    line = line.played(lineMove(position, board, token.substring(1))!.move);
  }
  return line;
}

TablePosition positionOf(TableLine line) =>
    (line.replay() as LineReplayed).position;

void main() {
  test('each board keeps its own moves and numbers', () {
    final line = playedLine('1e2e4 2d2d4 1e7e5');
    expect(line.of(BoardNumber.one).map((m) => m.san), ['e4', 'e5']);
    expect(line.of(BoardNumber.two).single.san, 'd4');
    expect(line.of(BoardNumber.one).last.number, 1);
    expect(line.upto(BoardNumber.one), 2);
  });

  test('one board steps back while the other stays where it is', () {
    final line = playedLine('1e2e4 2d2d4 1e7e5').go(BoardNumber.one, 1);
    final position = positionOf(line);
    expect(position.turn(BoardNumber.one).name, 'black');
    expect(line.current(BoardNumber.two)!.san, 'd4');
    // The move stepped past is still there to step forward into.
    expect(line.of(BoardNumber.one).length, 2);
  });

  test('replaying the next move steps forward instead of branching', () {
    final back = playedLine('1e2e4 1e7e5').go(BoardNumber.one, 1);
    final again = playedLine('1e7e5', back);
    expect(again.moves.length, 2);
    expect(again.upto(BoardNumber.one), 2);
  });

  test('a different move replaces that board’s later moves only', () {
    final back = playedLine('1e2e4 2d2d4 1e7e5 2d7d5').go(BoardNumber.one, 1);
    final line = playedLine('1c7c5', back);
    expect(line.of(BoardNumber.one).map((m) => m.san), ['e4', 'c5']);
    expect(line.of(BoardNumber.two).map((m) => m.san), ['d4', 'd5']);
  });

  test('stepping back past a capture the other board dropped breaks', () {
    // Board 1's exd5 gives board 2's Black a pawn, which it drops.
    final line = playedLine('1e2e4 1d7d5 1e4d5 2e2e4 2P@d5');
    final back = line.go(BoardNumber.one, 2);
    final replay = back.replay();
    expect(replay, isA<LineBroken>());
    expect((replay as LineBroken).move.san, 'P@d5');
  });

  test('a move is filed after the last one on the boards', () {
    // Board 2 steps back; board 1 moves on: the new move comes after d4
    // in the order played, ahead of the board 2 move that was stepped past.
    final line = playedLine('1e2e4 2d2d4 2d7d5').go(BoardNumber.two, 1);
    final next = playedLine('1e7e5', line);
    expect(next.moves.map((m) => m.san), ['e4', 'd4', 'e5', 'd5']);
    expect(next.applied.map((m) => m.san), ['e4', 'd4', 'e5']);
  });

  test('an illegal move is not a line move', () {
    expect(lineMove(TablePosition.initial, BoardNumber.one, 'e2e5'), isNull);
  });
}
