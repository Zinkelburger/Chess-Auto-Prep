import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/chess/bughouse/table_line.dart';
import 'package:dartchess/dartchess.dart' show Role, Side;
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

/// [line] with [board] at its [count]th move along its line.
TableLine stepped(TableLine line, BoardNumber board, int count) {
  final moves = [
    for (final n in line.lineOf(board))
      if (line.entry(n) is LineMove) n,
  ];
  return line.goTo(board, count == 0 ? null : moves[count - 1]);
}

/// The SAN of [board]'s moves at [node]'s continuations, main first.
List<String> sansAfter(TableLine line, BoardNumber board, int? node) => [
  for (final n in line.children(board, node)) (line.entry(n) as LineMove).san,
];

void main() {
  test('each board keeps its own moves and numbers', () {
    final line = playedLine('1e2e4 2d2d4 1e7e5');
    expect(line.of(BoardNumber.one).map((m) => m.san), ['e4', 'e5']);
    expect(line.of(BoardNumber.two).single.san, 'd4');
    expect(line.of(BoardNumber.one).last.number, 1);
    expect(line.upto(BoardNumber.one), 2);
  });

  test('one board steps back while the other stays where it is', () {
    final line = stepped(playedLine('1e2e4 2d2d4 1e7e5'), BoardNumber.one, 1);
    final position = positionOf(line);
    expect(position.turn(BoardNumber.one).name, 'black');
    expect(line.current(BoardNumber.two)!.san, 'd4');
    // The move stepped past is still there to step forward into.
    expect(line.of(BoardNumber.one).length, 2);
  });

  test('replaying the next move steps forward instead of branching', () {
    final back = stepped(playedLine('1e2e4 1e7e5'), BoardNumber.one, 1);
    final again = playedLine('1e7e5', back);
    expect(again.moves.length, 2);
    expect(again.upto(BoardNumber.one), 2);
  });

  test('a different move is a variation; the main line stays first', () {
    final back = stepped(
      playedLine('1e2e4 2d2d4 1e7e5 2d7d5'),
      BoardNumber.one,
      1,
    );
    final line = playedLine('1c7c5 1g1f3', back);
    final e4 = line.children(BoardNumber.one, null).single;
    expect(sansAfter(line, BoardNumber.one, e4), ['e5', 'c5']);
    // The board is on the variation; the other board kept its moves.
    expect(line.of(BoardNumber.one).map((m) => m.san), ['e4', 'c5', 'Nf3']);
    expect(line.of(BoardNumber.two).map((m) => m.san), ['d4', 'd5']);
    expect(line.isMain(line.at(BoardNumber.one)!), isFalse);
    // Playing the main move again steps into it rather than adding one.
    final main = playedLine('1e7e5', stepped(line, BoardNumber.one, 1));
    expect(main.moves.length, line.moves.length);
    expect(main.isMain(main.at(BoardNumber.one)!), isTrue);
  });

  test('promoting a variation puts it first; making it main does so '
      'all the way up', () {
    // 1. e4 e5 (1... c5 2. Nf3 (2. Nc3))
    var line = playedLine('1e2e4 1e7e5');
    line = playedLine('1c7c5 1g1f3', stepped(line, BoardNumber.one, 1));
    final c5 = line.children(
      BoardNumber.one,
      line.lineOf(BoardNumber.one)[0],
    )[1];
    line = playedLine('1b1c3', line.goTo(BoardNumber.one, c5));
    final nc3 = line.at(BoardNumber.one)!;
    final e4 = line.children(BoardNumber.one, null).single;

    final promoted = line.promoted(nc3);
    expect(sansAfter(promoted, BoardNumber.one, c5), ['Nc3', 'Nf3']);
    expect(sansAfter(promoted, BoardNumber.one, e4), ['e5', 'c5']);

    final main = line.mainLineThrough(nc3);
    expect(sansAfter(main, BoardNumber.one, e4), ['c5', 'e5']);
    expect(main.isMain(nc3), isTrue);
    // Arranging lines does not move either board.
    expect(main.at(BoardNumber.one), line.at(BoardNumber.one));
  });

  test('stepping back past a capture the other board dropped breaks', () {
    // Board 1's exd5 gives board 2's Black a pawn, which it drops.
    final line = playedLine('1e2e4 1d7d5 1e4d5 2e2e4 2P@d5');
    final back = stepped(line, BoardNumber.one, 2);
    final replay = back.replay();
    expect(replay, isA<LineBroken>());
    expect((replay as LineBroken).move.san, 'P@d5');
  });

  test('the boards replay in the order their moves were made', () {
    final line = stepped(playedLine('1e2e4 2d2d4 2d7d5'), BoardNumber.two, 1);
    final next = playedLine('1e7e5', line);
    expect(next.moves.map((m) => m.san), ['e4', 'd4', 'd5', 'e5']);
    expect(next.applied.map((m) => m.san), ['e4', 'd4', 'e5']);
  });

  test('an illegal move is not a line move', () {
    expect(lineMove(TablePosition.initial, BoardNumber.one, 'e2e5'), isNull);
  });

  test('the line through a move is what was on the boards when it was '
      'played', () {
    final line = playedLine('1e2e4 2d2d4 1e7e5 2d7d5');
    final e5 = line.at(BoardNumber.one)!;
    final through = line.through(e5);
    expect(through.moves.map((m) => m.san), ['e4', 'd4', 'e5']);
    expect(through.upto(BoardNumber.one), 2);
    expect(through.upto(BoardNumber.two), 1);
    // A variation keeps only its own line.
    final branched = playedLine('1c7c5', stepped(line, BoardNumber.one, 1));
    final c5 = branched.through(branched.at(BoardNumber.one)!);
    expect(c5.moves.map((m) => m.san), ['e4', 'd4', 'd5', 'c5']);
  });

  test('on the boards leaves out the moves stepped past', () {
    final line = stepped(
      stepped(playedLine('1e2e4 2d2d4 1e7e5'), BoardNumber.two, 0),
      BoardNumber.one,
      1,
    );
    final now = line.onBoards;
    expect(now.moves.map((m) => m.san), ['e4']);
    expect(positionOf(now).dualFen, positionOf(line).dualFen);
  });

  test('deleting takes a move, what follows it and its variations; '
      'the other board stays', () {
    var line = playedLine('1e2e4 2d2d4 1e7e5 1g1f3');
    line = playedLine('1b1c3', stepped(line, BoardNumber.one, 2));
    final e5 = line.lineOf(BoardNumber.one)[1];
    final cut = line.without(e5);
    expect(cut.of(BoardNumber.one).map((m) => m.san), ['e4']);
    expect(cut.moves.map((m) => m.san), ['e4', 'd4']);
    expect(cut.of(BoardNumber.two).single.san, 'd4');
    expect(cut.upto(BoardNumber.one), 1);
    // A cursor before the cut stays where it was.
    final back = stepped(line, BoardNumber.one, 0).without(e5);
    expect(back.at(BoardNumber.one), isNull);
    expect(back.of(BoardNumber.one).length, 1);
  });

  test('deleting the capture a drop needed breaks the replay', () {
    final line = playedLine('1e2e4 1d7d5 1e4d5 2e2e4 2P@d5');
    final exd5 = line.lineOf(BoardNumber.one)[2];
    expect(line.without(exd5).replay(), isA<LineBroken>());
  });

  test('presses at the end of a line are one hand edit; one that comes '
      'back to nothing is gone', () {
    var line = playedLine('1e2e4');
    line = line.edited(BoardNumber.one, Side.black, Role.knight, 1);
    line = line.edited(BoardNumber.one, Side.white, Role.pawn, 1);
    line = line.edited(BoardNumber.one, Side.black, Role.knight, 1);
    final edit = line.entry(line.at(BoardNumber.one)!) as HandEdit;
    expect(handChangeText(edit.changes), '+P +2n');
    expect(line.nodes.length, 2);
    line = line.edited(BoardNumber.one, Side.white, Role.pawn, -1);
    line = line.edited(BoardNumber.one, Side.black, Role.knight, -2);
    expect(line.nodes.length, 1);
    expect(line.current(BoardNumber.one)!.san, 'e4');
  });

  test('a hand edit where the board goes on is a variation', () {
    final line = stepped(
      playedLine('1e2e4 1e7e5'),
      BoardNumber.one,
      1,
    ).edited(BoardNumber.one, Side.black, Role.queen, 1);
    final e4 = line.children(BoardNumber.one, null).single;
    expect(line.children(BoardNumber.one, e4).length, 2);
    expect(line.of(BoardNumber.one).map((m) => m.san), ['e4']);
    expect(positionOf(line).one.pockets!.of(Side.black, Role.queen), 1);
  });
}
