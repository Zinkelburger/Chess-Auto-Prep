import 'package:dartchess/dartchess.dart' show Side, Square;
import 'package:flutter/foundation.dart';

import '../../chess/bughouse/hivemind.dart';
import '../../chess/bughouse/table.dart';
import '../../chess/bughouse/table_line.dart';
import '../../chess/bughouse/table_setup.dart';

/// The Bughouse lab's table: the two boards, the line played on them with a
/// cursor per board, the question the tables and the engine answer — our
/// team, the clock, a board that must be moved on, how long to search —
/// and what the user is pointing at.
///
/// A scratchpad: nothing here is saved. Leaving the mode keeps the table
/// for when the user comes back; quitting the app loses it.
final class BughouseLab extends ChangeNotifier {
  TableLine _line = const TableLine(TablePosition.initial);
  TablePosition _position = TablePosition.initial;
  BoardNumber _focus = BoardNumber.one;
  Team _team = Team.ab;
  ClockCase _clock = ClockCase.even;
  MustMove _mustMove = MustMove.either;
  Duration _budget = searchBudgets.first;
  bool _flipped = false;
  TableRefusal? _problem;
  Map<BoardNumber, String> _setupProblems = const {};

  /// The move a table row, an analysis row or an archive row is pointing
  /// at, drawn as an arrow on its board. Apart from the rest, so a pointer
  /// crossing the rows repaints the boards and nothing else.
  final preview = ValueNotifier<LabPreview?>(null);

  TableLine get line => _line;
  TablePosition get position => _position;

  /// The board the arrow keys and the step buttons act on: the one last
  /// moved or stepped on.
  BoardNumber get focus => _focus;
  Team get team => _team;
  ClockCase get clock => _clock;
  MustMove get mustMove => _mustMove;
  Duration get budget => _budget;
  bool get flipped => _flipped;

  /// Why the last move or step was refused, for the status line.
  TableRefusal? get problem => _problem;

  /// What is wrong in each board's setup boxes after `Set position`.
  Map<BoardNumber, String> get setupProblems => _setupProblems;

  /// The colour at the bottom of [board]: our team's, unless flipped.
  Side bottom(BoardNumber board) {
    final ours = _team.sideOn(board);
    return _flipped ? ours.opposite : ours;
  }

  /// Plays [uci] on [board] from the table on screen: from the board, a
  /// table row or the archive.
  void play(BoardNumber board, String uci) {
    final played = lineMove(_position, board, uci);
    if (played == null) {
      _refuse(_illegal(board, uci));
      return;
    }
    _line = _line.played(played.move);
    _show(played.after, focus: board);
  }

  /// [line] on the boards, every move of it played, as a match's game is
  /// shown; a line that does not replay is not shown.
  void showLine(TableLine line) {
    if (line.replay() case LineReplayed(:final position)) {
      _line = line;
      _setupProblems = const {};
      _show(position, focus: _focus);
    }
  }

  /// Both halves of an engine's joint action, board 1 first; a sitting
  /// board keeps its moves.
  void playJoint(JointMove joint) {
    var line = _line;
    var position = _position;
    for (final board in BoardNumber.values) {
      final uci = joint.on(board);
      if (uci == null) continue;
      final played = lineMove(position, board, uci);
      if (played == null) {
        _refuse(const LineMisfits());
        return;
      }
      line = line.played(played.move);
      position = played.after;
    }
    _line = line;
    _show(position, focus: _focus);
  }

  /// [board] stepped to its first [count] moves, unless the other board's
  /// moves would no longer play from there.
  void go(BoardNumber board, int count) {
    final next = _line.go(board, count);
    switch (next.replay()) {
      case LineReplayed(:final position):
        _line = next;
        _show(position, focus: board);
      case LineBroken(:final move):
        _focus = board;
        _refuse(StepRefused(move));
    }
  }

  /// The focused board a move forward (1) or back (−1).
  void step(int by) => go(_focus, _line.upto(_focus) + by);

  void toStart() => go(_focus, 0);

  void toEnd() => go(_focus, _line.of(_focus).length);

  /// A new game from the start; the team and the clock stay.
  void newGame() => _reset(TablePosition.initial);

  /// The table from the setup boxes, as a new line from there.
  void setPosition(BoardBoxes one, BoardBoxes two) {
    switch (readBoxes(one, two)) {
      case SetupReady(:final position):
        _reset(position);
      case SetupRefused(:final problems):
        _setupProblems = problems;
        notifyListeners();
    }
  }

  /// A pasted dual FEN, as a new line from there.
  void loadDualFen(String text) {
    switch (readDualFen(text)) {
      case SetupReady(:final position):
        _reset(position);
      case SetupRefused(:final problems):
        _setupProblems = problems;
        notifyListeners();
    }
  }

  void flip() => _change(() => _flipped = !_flipped);

  void setTeam(Team team) => _change(() => _team = team);

  void setClock(ClockCase clock) => _change(() => _clock = clock);

  void setMustMove(MustMove mustMove) => _change(() => _mustMove = mustMove);

  void setBudget(Duration budget) => _change(() => _budget = budget);

  /// The board the user is working on, when they click into its half.
  void focusOn(BoardNumber board) {
    if (board != _focus) _change(() => _focus = board);
  }

  void _reset(TablePosition position) {
    _line = TableLine(position);
    _setupProblems = const {};
    _show(position, focus: BoardNumber.one);
  }

  void _show(TablePosition position, {required BoardNumber focus}) {
    _position = position;
    _focus = focus;
    _problem = null;
    preview.value = null;
    notifyListeners();
  }

  void _refuse(TableRefusal problem) {
    _problem = problem;
    notifyListeners();
  }

  void _change(VoidCallback change) {
    change();
    notifyListeners();
  }

  /// Why [uci] cannot be played on [board].
  TableRefusal _illegal(BoardNumber board, String uci) {
    if (uci.contains('@')) return const DropRefused();
    final from = Square.parse(uci.length >= 2 ? uci.substring(0, 2) : '');
    final piece = from == null
        ? null
        : _position.board(board).board.pieceAt(from);
    if (piece != null && piece.color != _position.turn(board)) {
      return NotOnMove(piece.color, board);
    }
    return MoveRefused(uci);
  }

  @override
  void dispose() {
    preview.dispose();
    super.dispose();
  }
}

/// Why a move or a step was not made.
sealed class TableRefusal {
  const TableRefusal();
}

/// A reserve piece put where it may not go.
final class DropRefused extends TableRefusal {
  const DropRefused();
}

/// A [side] piece moved on [board] while the other side is on move there.
final class NotOnMove extends TableRefusal {
  const NotOnMove(this.side, this.board);

  final Side side;
  final BoardNumber board;
}

final class MoveRefused extends TableRefusal {
  const MoveRefused(this.uci);

  final String uci;
}

/// An engine's joint action from a table no longer on the boards.
final class LineMisfits extends TableRefusal {
  const LineMisfits();
}

/// A step that would leave [move], on the other board, without the piece
/// it dropped.
final class StepRefused extends TableRefusal {
  const StepRefused(this.move);

  final LineMove move;
}

/// A move being pointed at: on one board, or a joint action over both.
typedef LabPreview = Map<BoardNumber, String>;

/// The Search chips: how long Analyze thinks for each team.
const searchBudgets = [
  Duration(seconds: 3),
  Duration(seconds: 10),
  Duration(seconds: 30),
];
