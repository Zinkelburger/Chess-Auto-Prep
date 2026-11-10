import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../chess/bughouse/bpgn_moves.dart';
import '../../chess/bughouse/crazyhouse_pgn.dart';
import '../../chess/bughouse/hivemind.dart';
import '../../chess/bughouse/table.dart';
import '../../chess/bughouse/table_game.dart';
import '../../chess/bughouse/table_line.dart';
import '../../chess/bughouse/table_setup.dart';

/// How many boards the Bughouse mode shows: board 1 alone, its partner
/// board held still behind it, or the whole table.
enum LabBoards {
  one('1 board'),
  two('2 boards');

  const LabBoards(this.label);

  final String label;
}

/// The Bughouse mode's table: the two boards, the line played on them with
/// a cursor per board, how many boards are shown, the clock case the engine
/// answers for, and what the user is pointing at. When the line is a game
/// from a BPGN, also who played it and the other games of its file.
///
/// A scratchpad: nothing here is saved. Leaving the mode keeps the table
/// for when the user comes back; quitting the app loses it.
final class BughouseLab extends ChangeNotifier {
  TableLine _line = const TableLine(TablePosition.initial);
  TablePosition _position = TablePosition.initial;
  BoardNumber _focus = BoardNumber.one;
  LabBoards _boards = LabBoards.one;
  ClockCase _clock = ClockCase.cdMaySit;
  bool _flipped = false;
  TableRefusal? _problem;
  TableGame? _game;
  List<String> _games = const [];
  int _gameAt = 0;
  String? _file;

  /// The move a table row, an analysis row or an archive row is pointing
  /// at, drawn as an arrow on its board. Apart from the rest, so a pointer
  /// crossing the rows repaints the boards and nothing else.
  final preview = ValueNotifier<LabPreview?>(null);

  TableLine get line => _line;
  TablePosition get position => _position;

  /// The board the arrow keys and the step buttons act on: the one last
  /// moved or stepped on.
  BoardNumber get focus => _focus;
  LabBoards get boards => _boards;
  bool get single => _boards == LabBoards.one;
  ClockCase get clock => _clock;
  bool get flipped => _flipped;

  /// Why the last move or step was refused, for the status line.
  TableRefusal? get problem => _problem;

  /// Who played the line on the boards and how it ended, when it was read
  /// from a BPGN with tags; null for a line made here.
  TableGame? get game => _game;

  /// How many games the opened file holds, and which is on the boards,
  /// from 0. One game, or a line made here, is not counted: 0.
  int get gameCount => _games.length;
  int get gameAt => _gameAt;

  /// What [seat]'s clock reads with the boards as they are: after its last
  /// move, or the time the game started with; null when the game notes
  /// neither.
  Duration? timeLeft(Seat seat) => _line.clock(seat) ?? _game?.startClock;

  /// The colour at the bottom of [board]: A + B's, unless flipped.
  Side bottom(BoardNumber board) {
    final ours = Team.ab.sideOn(board);
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

  /// [line] on the boards, every move of it played; a line that does not
  /// replay is not shown.
  void showLine(TableLine line) {
    if (line.replay() case LineReplayed(:final position)) {
      _line = line;
      _show(position, focus: _focus);
    }
  }

  /// [moves] played in order from the table on screen: an engine line up to
  /// the move clicked. All or nothing: when one no longer plays, none is
  /// played and the line is said not to fit.
  void playMoves(List<(BoardNumber, String)> moves) {
    var line = _line;
    var position = _position;
    for (final (board, uci) in moves) {
      final played = lineMove(position, board, uci);
      if (played == null) {
        _refuse(const LineMisfits());
        return;
      }
      line = line.played(played.move);
      position = played.after;
    }
    if (moves.isEmpty) return;
    _line = line;
    _show(position, focus: _focus);
  }

  /// [board] at [node] of its lines (null for its start), with the other
  /// board where it was when that move was made, so every drop on either
  /// has its piece; [board] alone when that table no longer replays.
  void goTo(BoardNumber board, int? node) => _stepTo([
    if (node == null) _line.beforeFirst(board) else _line.asAt(node),
    _line.goTo(board, node),
  ], focus: board);

  /// The first of [ways] that replays, on the boards; when none does, the
  /// boards stay and the move that would not play is named.
  void _stepTo(Iterable<TableLine> ways, {BoardNumber? focus}) {
    LineMove? broken;
    for (final next in ways) {
      switch (next.replay()) {
        case LineReplayed(:final position):
          final moved = focus ?? _moved(next);
          _line = next;
          _show(position, focus: moved);
          return;
        case LineBroken(:final move):
          broken ??= move;
      }
    }
    if (broken == null) return;
    if (focus != null) _focus = focus;
    _refuse(StepRefused(broken));
  }

  /// The board a step to [next] moves: the one whose place changes, the
  /// later-made of the two when both do, the focused one when neither.
  BoardNumber _moved(TableLine next) {
    final changed = [
      for (final board in BoardNumber.values)
        if (next.at(board) != _line.at(board)) board,
    ];
    if (changed.length != 2) return changed.firstOrNull ?? _focus;
    final one = next.at(BoardNumber.one) ?? -1;
    final two = next.at(BoardNumber.two) ?? -1;
    return one > two ? BoardNumber.one : BoardNumber.two;
  }

  /// [node] and everything after it on its board taken out of the line,
  /// variations too; the other board's moves stay. Refused when one of those
  /// dropped a piece a move taken out had captured.
  void deleteFrom(int node) {
    final board = _line.nodes[node].board;
    final next = _line.without(node);
    switch (next.replay()) {
      case LineReplayed(:final position):
        _line = next;
        _show(position, focus: board);
      case LineBroken(move: final broken):
        _focus = board;
        _refuse(DeleteRefused(broken));
    }
  }

  /// What ← and → do. With one board, board 1 a step forward (1) or back
  /// (−1). With two, the game a step in the order its moves were made:
  /// forward plays the next move of the two boards' lines, back takes the
  /// last one made off.
  void step(int by) {
    if (single) return stepOn(_focus, by);
    if (by > 0) return _stepTo(_line.stepsOn);
    if (_line.steppedBack case final back?) _stepTo([back]);
  }

  /// [board] a step forward (1), along its main continuation, or back (−1),
  /// as [goTo] goes there; nothing at either end.
  void stepOn(BoardNumber board, int by) {
    final at = _line.at(board);
    if (by < 0 && at != null) goTo(board, _line.nodes[at].parent);
    if (by > 0) {
      if (_line.mainChild(board, at) case final next?) goTo(board, next);
    }
  }

  /// Board 1 at its start with one board; with two, both at theirs.
  void toStart() =>
      single ? goTo(_focus, null) : _stepTo([_line.atStart], focus: _focus);

  /// Board 1 at the end of the line it is on with one board; with two,
  /// both boards at the ends of theirs, or as far on as the moves play in
  /// the order made.
  void toEnd() {
    if (single) {
      final line = _line.lineOf(_focus);
      if (line.isNotEmpty) goTo(_focus, line.last);
      return;
    }
    var end = _line.atEnd;
    if (end.replay() is! LineReplayed) {
      end = _line;
      for (var steps = 0; steps < _line.nodes.length; steps++) {
        final next = end.stepsOn
            .where((way) => way.replay() is LineReplayed)
            .firstOrNull;
        if (next == null) break;
        end = next;
      }
    }
    _stepTo([end], focus: _focus);
  }

  /// The variation [node] is in one place up among the lines there.
  void promote(int node) => _arrange(_line.promoted(node));

  /// [node]'s line made its board's main line.
  void makeMainLine(int node) => _arrange(_line.mainLineThrough(node));

  void _arrange(TableLine line) {
    _line = line;
    notifyListeners();
  }

  /// A new game from the start; the clock stays.
  void newGame() => _reset(TablePosition.initial);

  /// One [role] more (+1) or fewer (−1) in [side]'s hand on [board], within
  /// 0…[handLimit], noted in the line after that board's move on screen, as
  /// the website notes it. The moves before it stay; that board's later
  /// moves go, as when a different move is played there.
  void adjustHand(BoardNumber board, Side side, Role role, int delta) {
    final count = _position.board(board).pockets!.of(side, role) + delta;
    if (count < 0 || count > handLimit) return;
    final edited = _line.edited(board, side, role, delta);
    if (edited.replay() case LineReplayed(:final position)) {
      _line = edited;
      _show(position, focus: board);
    }
  }

  /// [board]'s pieces, side to move and castling from [setup], its hands
  /// kept, as the start of a new line. Refused when no game could go on from
  /// there.
  void editBoard(BoardNumber board, Setup setup) {
    final hands = _position.board(board).pockets;
    try {
      final edited = Crazyhouse.fromSetup(
        Setup(
          board: setup.board,
          pockets: hands,
          turn: setup.turn,
          castlingRights: setup.castlingRights,
          epSquare: setup.epSquare,
          halfmoves: setup.halfmoves,
          fullmoves: setup.fullmoves,
        ),
      );
      _reset(_position.withBoard(board, edited), focus: board);
    } on PositionSetupException {
      _refuse(const PositionRefused('That board cannot be played from.'));
    }
  }

  /// A pasted dual FEN, or one board's FEN for board 1, as a new line from
  /// there.
  void loadDualFen(String text) {
    switch (readDualFen(text)) {
      case SetupReady(:final position):
        _reset(position);
      case SetupRefused(:final problems):
        _refuse(PositionRefused(problems.values.join(' ')));
    }
  }

  /// Each board's line as the mode copies it, a whole BPGN game when the
  /// line is one (see [tableLineText]).
  String get movesText => tableLineText(_line, game: _game);

  /// The line up to and including [node] as a PGN: with one board, a
  /// crazyhouse PGN of board 1 that Lichess imports; with two, the BPGN
  /// [movesText] writes.
  String linePgnThrough(int node) {
    final line = _line.through(node);
    return single
        ? crazyhouseLinePgn(line, _line.nodes[node].board)
        : tableLineText(line);
  }

  /// The table just after [node], as the line up to it leaves it; null when
  /// that no longer replays.
  TablePosition? positionAfter(int node) =>
      switch (_line.through(node).replay()) {
        LineReplayed(:final position) => position,
        LineBroken() => null,
      };

  /// The line on the boards now, followed by [moves] as far as they play,
  /// as a PGN: what an engine line copies.
  String linePgnWith(List<(BoardNumber, String)> moves) {
    var line = _line.onBoards;
    var position = _position;
    for (final (board, uci) in moves) {
      final played = lineMove(position, board, uci);
      if (played == null) break;
      line = line.played(played.move);
      position = played.after;
    }
    return single
        ? crazyhouseLinePgn(line, BoardNumber.one)
        : tableLineText(line);
  }

  /// Pasted BPGN as a new line, every move played; refused whole when one
  /// does not play. [file] names the file it was read from, when it was
  /// opened rather than pasted: a pasted line is shown at its end, to go on
  /// from, and an opened game at its start, to play through. Moves on board
  /// 2 show both boards. Text with several games shows the first, the rest
  /// a step away with [showGame].
  void pasteMoves(String text, {String? file}) {
    final games = bpgnGames(text);
    if (games.length > 1) {
      _games = games;
      _file = file;
      showGame(0);
      return;
    }
    switch (readTableLineText(text)) {
      case PastedLine(:final line, :final game):
        _games = const [];
        _gameAt = 0;
        _file = null;
        _game = game;
        _bothBoardsFor(line);
        if (file != null) _focus = BoardNumber.one;
        showLine(file == null ? line : line.atStart);
      case PastedMovesRefused(:final token):
        _refuse(MovesRefused(token, file: file));
    }
  }

  /// Game [index] of the opened file on the boards, at its start. One that
  /// does not play is shown without its moves, with the move that broke it
  /// named, so the games after it can still be reached.
  void showGame(int index) {
    if (index < 0 || index >= _games.length) return;
    _gameAt = index;
    _focus = BoardNumber.one;
    switch (readTableLineText(_games[index])) {
      case PastedLine(:final line, :final game):
        _game = game;
        _bothBoardsFor(line);
        showLine(line.atStart);
      case PastedMovesRefused(:final token):
        _game = tableGameOf(_games[index]);
        _line = const TableLine(TablePosition.initial);
        _position = TablePosition.initial;
        preview.value = null;
        _refuse(MovesRefused(token, file: _file));
    }
  }

  void _bothBoardsFor(TableLine line) {
    if (line.nodes.any((node) => node.board == BoardNumber.two)) {
      _boards = LabBoards.two;
    }
  }

  /// The file called [file] could not be read; the boards stay as they are.
  void fileUnread(String file) => _refuse(FileUnread(file));

  void flip() => _change(() => _flipped = !_flipped);

  void setClock(ClockCase clock) => _change(() => _clock = clock);

  /// One board or both; with one, the keys step board 1.
  void showBoards(LabBoards boards) => _change(() {
    _boards = boards;
    if (single) _focus = BoardNumber.one;
  });

  /// The board the user is working on, when they click into its half.
  void focusOn(BoardNumber board) {
    if (board != _focus) _change(() => _focus = board);
  }

  /// A new line from [position], which is no game of a file.
  void _reset(TablePosition position, {BoardNumber focus = BoardNumber.one}) {
    _game = null;
    _games = const [];
    _gameAt = 0;
    _file = null;
    _line = TableLine(position);
    _show(position, focus: focus);
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

/// A step that would leave [move] without the piece it dropped: the capture
/// it came from, on the other board, is no longer in the line.
final class StepRefused extends TableRefusal {
  const StepRefused(this.move);

  final LineMove move;
}

/// A delete that would leave [move], on the other board, without the piece
/// it dropped.
final class DeleteRefused extends TableRefusal {
  const DeleteRefused(this.move);

  final LineMove move;
}

/// A pasted position or an edited board that could not be played from;
/// [reason] says why.
final class PositionRefused extends TableRefusal {
  const PositionRefused(this.reason);

  final String reason;
}

/// Pasted moves that were not taken: [token] is the first that does not
/// play, or null when there were no bughouse moves in the text. [file] is
/// the file they were opened from, or null when they were pasted.
final class MovesRefused extends TableRefusal {
  const MovesRefused(this.token, {this.file});

  final String? token;
  final String? file;
}

/// A file opened for its moves that could not be read.
final class FileUnread extends TableRefusal {
  const FileUnread(this.file);

  final String file;
}

/// A move being pointed at: on one board, or a joint action over both.
typedef LabPreview = Map<BoardNumber, String>;
