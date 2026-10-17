import 'package:dartchess/dartchess.dart' show Role, Side;

import 'table.dart';

/// One step of a table's line, on one board: a move, or a hand edit.
sealed class LineEntry {
  const LineEntry({required this.board});

  final BoardNumber board;
}

/// One move of a table's line: which board, the move both ways, who made it
/// and the number that board gives it.
final class LineMove extends LineEntry {
  const LineMove({
    required super.board,
    required this.uci,
    required this.san,
    required this.side,
    required this.number,
  });

  final String uci;
  final String san;
  final Side side;
  final int number;
}

/// [count] more (or, negative, fewer) [role] in [side]'s hand on [board],
/// made after that board's first [after] moves, as on the website: the
/// moves before it stay, and it holds for every move after it.
final class HandEdit extends LineEntry {
  const HandEdit({
    required super.board,
    required this.after,
    required this.side,
    required this.role,
    required this.count,
  });

  final int after;
  final Side side;
  final Role role;
  final int count;
}

/// One piece's net change in a hand: [count] more, or fewer when negative.
typedef HandChange = ({Side side, Role role, int count});

/// Both boards' moves and hand edits in the order they were made, with a
/// cursor per board.
///
/// The boards are two games, so each steps back and forth through its own
/// moves: the position is the start plus each board's first `upto(board)`
/// moves, and the hand edits made after them, replayed in the order they
/// were made. A capture crosses boards, so stepping one board back can take
/// away the piece the other board dropped; [replay] then answers where the
/// line breaks and the step is refused. Stepping back and playing a
/// different move, or editing a hand, replaces that board's later moves and
/// keeps the other board's.
final class TableLine {
  const TableLine(this.root) : entries = const [], _upto = const (0, 0);

  const TableLine._(this.root, this.entries, this._upto);

  final TablePosition root;

  /// Every move and hand edit, both boards, in the order made; those past a
  /// board's cursor are still here to step forward into.
  final List<LineEntry> entries;
  final (int, int) _upto;

  /// Every move, both boards, in the order played.
  List<LineMove> get moves => entries.whereType<LineMove>().toList();

  /// How many of [board]'s moves are on the board.
  int upto(BoardNumber board) => board == BoardNumber.one ? _upto.$1 : _upto.$2;

  List<LineMove> of(BoardNumber board) => [
    for (final move in moves)
      if (move.board == board) move,
  ];

  /// The moves on the boards now, in the order they were played.
  List<LineMove> get applied => _applied.whereType<LineMove>().toList();

  /// The moves and hand edits on the boards now, in the order made. A hand
  /// edit is on its board from the move it follows onwards.
  List<LineEntry> get _applied {
    final seen = {BoardNumber.one: 0, BoardNumber.two: 0};
    final on = <LineEntry>[];
    for (final entry in entries) {
      switch (entry) {
        case LineMove(:final board):
          final count = seen[board]!;
          seen[board] = count + 1;
          if (count < upto(board)) on.add(entry);
        case HandEdit(:final board, :final after):
          if (after <= upto(board)) on.add(entry);
      }
    }
    return on;
  }

  /// The last move on [board] now, for its highlight and its list.
  LineMove? current(BoardNumber board) {
    final count = upto(board);
    return count == 0 ? null : of(board)[count - 1];
  }

  /// The hands' net change on [board] after its first [after] moves, White's
  /// then Black's, pawn to queen; empty when there is none.
  List<HandChange> handChanges(BoardNumber board, int after) {
    final net = <(Side, Role), int>{};
    for (final entry in entries) {
      if (entry case HandEdit(
        board: final b,
        after: final a,
        :final side,
        :final role,
        :final count,
      ) when b == board && a == after) {
        net[(side, role)] = (net[(side, role)] ?? 0) + count;
      }
    }
    return [
      for (final side in Side.values)
        for (final role in reserveRoles)
          if (net[(side, role)] case final count? when count != 0)
            (side: side, role: role, count: count),
    ];
  }

  /// [board] stepped to its first [count] moves.
  TableLine go(BoardNumber board, int count) {
    final at = count.clamp(0, of(board).length);
    return TableLine._(
      root,
      entries,
      board == BoardNumber.one ? (at, _upto.$2) : (_upto.$1, at),
    );
  }

  /// [move] played at [board]'s cursor: the next move already there when it
  /// is the same one, or a new one that replaces what followed on that
  /// board. It goes in after the last move now on either board. The other
  /// board's moves past its cursor stay, even one whose drop needed a
  /// capture this replaces: stepping into it is refused, as [replay] says,
  /// rather than a move the user played being thrown away.
  TableLine played(LineMove move) {
    final board = move.board;
    final own = of(board);
    final at = upto(board);
    if (at < own.length && own[at].uci == move.uci) return go(board, at + 1);
    final (kept, insertAt) = _cutAt(board);
    final next = TableLine._(root, [...kept]..insert(insertAt, move), _upto);
    return next.go(board, at + 1);
  }

  /// [by] more (or, negative, fewer) [role] in [side]'s hand on [board],
  /// noted after the move on that board now. Several edits of one piece
  /// there are one edit; one that comes back to nothing is gone. Like a
  /// move, it replaces that board's later moves.
  TableLine edited(BoardNumber board, Side side, Role role, int by) {
    final at = upto(board);
    final (kept, insertAt) = _cutAt(board);
    // The edits just made on this board, after the last move on either.
    for (var i = insertAt - 1; i >= 0; i--) {
      final edit = kept[i];
      if (edit is! HandEdit || edit.board != board || edit.after != at) break;
      if (edit.side != side || edit.role != role) continue;
      final count = edit.count + by;
      kept.removeAt(i);
      if (count != 0) kept.insert(i, _edit(board, at, side, role, count));
      return TableLine._(root, kept, _upto);
    }
    kept.insert(insertAt, _edit(board, at, side, role, by));
    return TableLine._(root, kept, _upto);
  }

  static HandEdit _edit(
    BoardNumber board,
    int after,
    Side side,
    Role role,
    int count,
  ) => HandEdit(
    board: board,
    after: after,
    side: side,
    role: role,
    count: count,
  );

  /// The entries without [board]'s moves and hand edits past its cursor, and
  /// the place after the last entry on the boards now, where a new one goes.
  (List<LineEntry>, int) _cutAt(BoardNumber board) {
    final at = upto(board);
    final dropped = {
      ...of(board).skip(at),
      for (final entry in entries)
        if (entry case HandEdit(
          board: final b,
          :final after,
        ) when b == board && after > at)
          entry,
    };
    final kept = [
      for (final entry in entries)
        if (!dropped.contains(entry)) entry,
    ];
    final onBoards = _applied.toSet();
    var insertAt = 0;
    for (final (i, entry) in kept.indexed) {
      if (onBoards.contains(entry)) insertAt = i + 1;
    }
    return (kept, insertAt);
  }

  /// The table after the moves and hand edits on the boards, or the first
  /// move that no longer plays. A hand edit keeps each count within
  /// 0…[handLimit].
  LineReplay replay() {
    var position = root;
    for (final entry in _applied) {
      switch (entry) {
        case LineMove(:final board, :final uci):
          final played = position.play(board, uci);
          if (played == null) return LineBroken(entry);
          position = played.after;
        case HandEdit(:final board, :final side, :final role, :final count):
          position = position.withHand(board, side, role, count);
      }
    }
    return LineReplayed(position);
  }
}

/// [changes] as the website writes them, `+N −2p`: White's pieces in upper
/// case, a count only when more than one.
String handChangeText(List<HandChange> changes) => [
  for (final (:side, :role, :count) in changes)
    '${count > 0 ? '+' : '−'}${count.abs() > 1 ? count.abs() : ''}'
        '${side == Side.white ? role.uppercaseLetter : role.letter}',
].join(' ');

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
    move: LineMove(
      board: board,
      uci: played.move.uci,
      san: played.move.san,
      side: before.turn,
      number: before.fullmoves,
    ),
  );
}
