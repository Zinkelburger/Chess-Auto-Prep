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

/// The hands on [board] changed by [changes], as the website notes it after
/// a move: the moves before it stay, and it holds for every move after it.
final class HandEdit extends LineEntry {
  const HandEdit({required super.board, required this.changes});

  /// The net change of each piece, White's then Black's, pawn to queen;
  /// never empty.
  final List<HandChange> changes;
}

/// One piece's net change in a hand: [count] more, or fewer when negative.
typedef HandChange = ({Side side, Role role, int count});

/// One move or hand edit in its board's tree of lines.
final class LineNode {
  const LineNode(this.entry, {required this.parent, required this.partner});

  final LineEntry entry;

  /// The node before it on its board, or null at the board's start.
  final int? parent;

  /// Where the other board was when this was made, or null at its start:
  /// what the line up to here keeps of the other board.
  final int? partner;

  BoardNumber get board => entry.board;
}

/// Both boards' moves and hand edits, each board a tree of lines as the
/// workspace's move list has, with a cursor per board.
///
/// The boards are two games, so each steps through its own tree: the
/// position is the start plus the nodes from each board's start to its
/// cursor, replayed in the order they were made. A capture crosses boards,
/// so stepping one board elsewhere can take away the piece the other board
/// dropped; [replay] then answers where the line breaks and the step is
/// refused. A move or hand edit made where the board already goes on is a
/// variation there; the board's first continuation is its main line.
final class TableLine {
  const TableLine(this.root)
    : nodes = const [],
      _children = const {},
      _at = const (null, null);

  const TableLine._(this.root, this.nodes, this._children, this._at);

  final TablePosition root;

  /// Every move and hand edit, both boards, every line, in the order made.
  /// A node's index is how the line names it.
  final List<LineNode> nodes;

  /// The continuations after each node of each board, the main one first;
  /// a board's start is `(board, null)`.
  final Map<(BoardNumber, int?), List<int>> _children;
  final (int?, int?) _at;

  bool get isEmpty => nodes.isEmpty;

  /// The node [board] is at, or null at its start.
  int? at(BoardNumber board) => board == BoardNumber.one ? _at.$1 : _at.$2;

  LineEntry entry(int node) => nodes[node].entry;

  /// The continuations after [node] on [board], the main one first.
  List<int> children(BoardNumber board, int? node) =>
      _children[(board, node)] ?? const [];

  int? mainChild(BoardNumber board, int? node) {
    final next = children(board, node);
    return next.isEmpty ? null : next.first;
  }

  /// The nodes from its board's start to [node], first to last.
  List<int> pathTo(int? node) {
    final path = <int>[];
    for (int? n = node; n != null; n = nodes[n].parent) {
      path.add(n);
    }
    return path.reversed.toList();
  }

  /// [board]'s line: from its start to its cursor, then on along each main
  /// continuation to the end.
  List<int> lineOf(BoardNumber board) {
    final line = pathTo(at(board));
    for (var n = mainChild(board, at(board)); n != null;) {
      line.add(n);
      n = mainChild(board, n);
    }
    return line;
  }

  /// The moves of [board]'s line.
  List<LineMove> of(BoardNumber board) => [
    for (final n in lineOf(board))
      if (nodes[n].entry case final LineMove move) move,
  ];

  /// How many of [board]'s moves are on the board.
  int upto(BoardNumber board) =>
      pathTo(at(board)).where((n) => nodes[n].entry is LineMove).length;

  /// Every move, both boards, every line, in the order played.
  List<LineMove> get moves =>
      nodes.map((n) => n.entry).whereType<LineMove>().toList();

  /// The nodes on the boards now, in the order made.
  List<int> get _applied => [...pathTo(_at.$1), ...pathTo(_at.$2)]..sort();

  /// The moves on the boards now, in the order they were played.
  List<LineMove> get applied => [
    for (final n in _applied)
      if (nodes[n].entry case final LineMove move) move,
  ];

  /// The last move on [board] now, for its highlight.
  LineMove? current(BoardNumber board) {
    for (int? n = at(board); n != null; n = nodes[n].parent) {
      if (nodes[n].entry case final LineMove move) return move;
    }
    return null;
  }

  /// Whether [node] is on its board's main line.
  bool isMain(int node) => pathTo(
    node,
  ).every((n) => mainChild(nodes[n].board, nodes[n].parent) == n);

  /// [board] at [node], which is null for its start.
  TableLine goTo(BoardNumber board, int? node) => TableLine._(
    root,
    nodes,
    _children,
    board == BoardNumber.one ? (node, _at.$2) : (_at.$1, node),
  );

  /// [move] played at its board's cursor: the continuation already there
  /// when it is the same move, or a new one, which is a variation when the
  /// board already goes on from there. The other board stays where it is.
  TableLine played(LineMove move) {
    final board = move.board;
    final from = at(board);
    for (final next in children(board, from)) {
      if (nodes[next].entry case LineMove(:final uci) when uci == move.uci) {
        return goTo(board, next);
      }
    }
    return _added(move);
  }

  /// [by] more (or, negative, fewer) [role] in [side]'s hand on [board],
  /// noted at its cursor. Presses on an edit nothing follows yet are one
  /// edit, and one that comes back to nothing is gone; elsewhere it is a new
  /// step, as a move is.
  TableLine edited(BoardNumber board, Side side, Role role, int by) {
    final from = at(board);
    if (from != null && children(board, from).isEmpty) {
      if (nodes[from] case LineNode(
        entry: HandEdit(:final changes),
        :final parent,
        :final partner,
      )) {
        final net = _merged(changes, side, role, by);
        if (net.isEmpty) return without(from);
        final edit = LineNode(
          HandEdit(board: board, changes: net),
          parent: parent,
          partner: partner,
        );
        return TableLine._(root, [...nodes]..[from] = edit, _children, _at);
      }
    }
    return _added(
      HandEdit(board: board, changes: [(side: side, role: role, count: by)]),
    );
  }

  TableLine _added(LineEntry entry) {
    final board = entry.board;
    final from = at(board);
    final id = nodes.length;
    return TableLine._(
      root,
      [...nodes, LineNode(entry, parent: from, partner: at(board.other))],
      {
        ..._children,
        (board, from): [...children(board, from), id],
      },
      _at,
    ).goTo(board, id);
  }

  /// The line as it stood when [node] was made: its board's path to it and
  /// the other board's path to where that board was then, each board at
  /// the end of it. What "the line up to this move" copies.
  TableLine through(int node) {
    final partner = nodes[node].partner;
    final board = nodes[node].board;
    return _only({
      ...pathTo(node),
      ...pathTo(partner),
    }, board == BoardNumber.one ? (node, partner) : (partner, node));
  }

  /// Only what is on the boards now, each board at its cursor: the line an
  /// engine's search from here continues.
  TableLine get onBoards => _only(_applied.toSet(), _at);

  /// Each board's line and nothing else, each at its end: what the moves
  /// copy as.
  TableLine get shown {
    final one = lineOf(BoardNumber.one);
    final two = lineOf(BoardNumber.two);
    return _only(
      {...one, ...two},
      (one.isEmpty ? null : one.last, two.isEmpty ? null : two.last),
    );
  }

  /// [node] and everything after it on its board taken out; a cursor in
  /// what went goes back to the node before [node]. The other board's moves
  /// stay: one that dropped a piece a move gone had captured no longer
  /// replays, and [replay] says so.
  TableLine without(int node) {
    final gone = <int>{};
    void take(int n) {
      gone.add(n);
      children(nodes[n].board, n).forEach(take);
    }

    take(node);
    return _only({
      for (var n = 0; n < nodes.length; n++)
        if (!gone.contains(n)) n,
    }, _at);
  }

  /// The variation [node] is in put one place up: the nearest step of its
  /// path that is not its parent's first continuation becomes the first.
  TableLine promoted(int node) {
    for (final n in pathTo(node).reversed) {
      if (mainChild(nodes[n].board, nodes[n].parent) != n) return _first(n);
    }
    return this;
  }

  /// [node] on its board's main line: every step of its path made its
  /// parent's first continuation.
  TableLine mainLineThrough(int node) {
    var line = this;
    for (final n in pathTo(node)) {
      line = line._first(n);
    }
    return line;
  }

  TableLine _first(int node) {
    final key = (nodes[node].board, nodes[node].parent);
    final siblings = children(key.$1, key.$2);
    if (siblings.first == node) return this;
    return TableLine._(root, nodes, {
      ..._children,
      key: [node, ...siblings.where((n) => n != node)],
    }, _at);
  }

  /// The line with only [keep], which holds the path to each node in it,
  /// renumbered in the order made. A cursor or partner outside it goes to
  /// the nearest node before it that is kept.
  TableLine _only(Set<int> keep, (int?, int?) at) {
    final kept = keep.toList()..sort();
    final renumbered = {for (final (i, n) in kept.indexed) n: i};
    int? map(int? node) {
      var n = node;
      while (n != null && !renumbered.containsKey(n)) {
        n = nodes[n].parent;
      }
      return n == null ? null : renumbered[n];
    }

    return TableLine._(
      root,
      [
        for (final n in kept)
          LineNode(
            nodes[n].entry,
            parent: map(nodes[n].parent),
            partner: map(nodes[n].partner),
          ),
      ],
      {
        for (final MapEntry(key: (board, parent), value: next)
            in _children.entries)
          if (parent == null || renumbered.containsKey(parent))
            (board, map(parent)): [for (final n in next) ?renumbered[n]],
      }..removeWhere((_, next) => next.isEmpty),
      (map(at.$1), map(at.$2)),
    );
  }

  /// The table after the moves and hand edits on the boards, or the first
  /// move that no longer plays. A hand edit keeps each count within
  /// 0…[handLimit].
  LineReplay replay() {
    var position = root;
    for (final n in _applied) {
      switch (nodes[n].entry) {
        case final LineMove move:
          final played = position.play(move.board, move.uci);
          if (played == null) return LineBroken(move);
          position = played.after;
        case HandEdit(:final board, :final changes):
          for (final (:side, :role, :count) in changes) {
            position = position.withHand(board, side, role, count);
          }
      }
    }
    return LineReplayed(position);
  }
}

/// [changes] with [by] more [role] for [side], White's then Black's, pawn
/// to queen, without the pieces that come back to nothing.
List<HandChange> _merged(
  List<HandChange> changes,
  Side side,
  Role role,
  int by,
) {
  final net = {
    for (final (:side, :role, :count) in changes) (side, role): count,
  };
  net[(side, role)] = (net[(side, role)] ?? 0) + by;
  return [
    for (final side in Side.values)
      for (final role in reserveRoles)
        if (net[(side, role)] case final count? when count != 0)
          (side: side, role: role, count: count),
  ];
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
