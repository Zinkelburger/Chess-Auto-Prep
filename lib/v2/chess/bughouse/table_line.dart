import 'package:dartchess/dartchess.dart' show Side;

import 'table.dart';

/// One move of a table's line: which board, the move both ways, who made it
/// and the number that board gives it.
typedef LineMove = ({
  BoardNumber board,
  String uci,
  String san,
  Side side,
  int number,
});

/// Both boards' moves in the order they were played, with a cursor per
/// board.
///
/// The boards are two games, so each steps back and forth through its own
/// moves: the position is the start plus each board's first `upto(board)`
/// moves, replayed in the order they were played. A capture crosses boards,
/// so stepping one board back can take away the piece the other board
/// dropped; [replay] then answers where the line breaks and the step is
/// refused. Stepping back and playing a different move replaces that
/// board's later moves and keeps the other board's.
final class TableLine {
  const TableLine(this.root) : moves = const [], _upto = const (0, 0);

  const TableLine._(this.root, this.moves, this._upto);

  final TablePosition root;

  /// Every move, both boards, in the order played; those past a board's
  /// cursor are still here to step forward into.
  final List<LineMove> moves;
  final (int, int) _upto;

  /// How many of [board]'s moves are on the board.
  int upto(BoardNumber board) => board == BoardNumber.one ? _upto.$1 : _upto.$2;

  List<LineMove> of(BoardNumber board) => [
    for (final move in moves)
      if (move.board == board) move,
  ];

  /// The moves on the boards now, in the order they were played.
  List<LineMove> get applied {
    var one = 0, two = 0;
    return [
      for (final move in moves)
        if (move.board == BoardNumber.one ? one++ < _upto.$1 : two++ < _upto.$2)
          move,
    ];
  }

  /// The last move on [board] now, for its highlight and its list.
  LineMove? current(BoardNumber board) {
    final count = upto(board);
    return count == 0 ? null : of(board)[count - 1];
  }

  /// [board] stepped to its first [count] moves.
  TableLine go(BoardNumber board, int count) {
    final at = count.clamp(0, of(board).length);
    return TableLine._(
      root,
      moves,
      board == BoardNumber.one ? (at, _upto.$2) : (_upto.$1, at),
    );
  }

  /// [move] played at [board]'s cursor: the next move already there when it
  /// is the same one, or a new one that replaces what followed on that
  /// board. It goes in after the last move now on either board.
  TableLine played(LineMove move) {
    final board = move.board;
    final own = of(board);
    final at = upto(board);
    if (at < own.length && own[at].uci == move.uci) return go(board, at + 1);
    final dropped = own.skip(at).toSet();
    final kept = [
      for (final m in moves)
        if (!dropped.contains(m)) m,
    ];
    final onBoards = applied.toSet();
    var insertAt = 0;
    for (final (i, m) in kept.indexed) {
      if (onBoards.contains(m)) insertAt = i + 1;
    }
    final next = TableLine._(root, [...kept]..insert(insertAt, move), _upto);
    return next.go(board, at + 1);
  }

  /// The table after the moves on the boards, or the first one that no
  /// longer plays.
  LineReplay replay() {
    var position = root;
    for (final move in applied) {
      final played = position.play(move.board, move.uci);
      if (played == null) return LineBroken(move);
      position = played.after;
    }
    return LineReplayed(position);
  }
}

sealed class LineReplay {
  const LineReplay();
}

final class LineReplayed extends LineReplay {
  const LineReplayed(this.position);

  final TablePosition position;
}

/// [move] cannot be played where the line now puts it: a drop whose piece
/// came from a capture the other board no longer has.
final class LineBroken extends LineReplay {
  const LineBroken(this.move);

  final LineMove move;
}

/// [move] on [position] as a line move, or null when it is not legal there.
({TablePosition after, LineMove move})? lineMove(
  TablePosition position,
  BoardNumber board,
  String uci,
) {
  final played = position.play(board, uci);
  if (played == null) return null;
  final before = position.board(board);
  return (
    after: played.after,
    move: (
      board: board,
      uci: played.move.uci,
      san: played.move.san,
      side: before.turn,
      number: before.fullmoves,
    ),
  );
}
