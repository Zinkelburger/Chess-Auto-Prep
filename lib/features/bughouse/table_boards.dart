import 'dart:math' as math;

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../chess/bughouse/table.dart';
import '../../chess/bughouse/table_game.dart';
import '../../chess/pgn/board_shapes.dart';
import '../../ui/listening_state.dart';
import '../../ui/theme.dart';
import '../../workspace/board/board_view.dart';
import 'bughouse_lab.dart';
import 'lab_engine.dart';
import 'lab_lines.dart';
import 'pocket.dart';

/// The boards on screen, each with its two players' hands: board 1 alone,
/// or both side by side, each with its engine's best moves under it. The
/// move lists are in the panel.
///
/// While the engine is on, each board shows its best moves as lila's
/// analysis board does: the engine's choice a pale blue arrow, the moves
/// close behind it thinner grey ones, a drop as a ring on its square with
/// the piece inside. A right-drag draws an arrow and a right-click a circle, in
/// lila's colours; a left click or a new position takes them away. The
/// wheel over a board steps that board.
///
/// Board 1 has A (White) and C (Black), board 2 D (White) and B (Black); our
/// team's colour is at the bottom of board 1 unless the boards are flipped.
/// A piece moves by click or drag; a hand's piece is dragged onto a square,
/// or clicked and then its square clicked, the squares it may go to ringed.
/// The − and + in a hand's slot, shown while the pointer is over it, take
/// one of that piece away or add one.
class TableBoards extends StatefulWidget {
  const TableBoards({
    super.key,
    required this.lab,
    required this.engine,
    required this.boardSize,
  });

  final BughouseLab lab;
  final LabEngine engine;
  final double boardSize;

  @override
  State<TableBoards> createState() => _TableBoardsState();
}

/// A reserve piece picked up by a click, for the next square clicked.
typedef _Picked = ({BoardNumber board, Side side, Role role});

class _TableBoardsState extends State<TableBoards>
    with ListeningState<TableBoards> {
  _Picked? _picked;

  /// The board whose hand a piece is being dragged from. Chessground takes a
  /// dragged piece on any board where its colour is on move, so a drop on
  /// the other board would play that board's own reserve piece.
  BoardNumber? _draggingFrom;

  BughouseLab get _lab => widget.lab;

  @override
  Listenable listenableOf(TableBoards widget) => widget.lab;

  @override
  void didUpdateWidget(TableBoards oldWidget) {
    if (oldWidget.lab != _lab) _picked = null;
    super.didUpdateWidget(oldWidget);
  }

  /// A move that took the picked-up piece's turn or reserve drops it.
  @override
  void changed() {
    if (_picked == null || _stillPicked(_lab.position) != null) return;
    setState(() => _picked = null);
  }

  void _pick(BoardNumber board, Role role) {
    if (!mounted) return;
    final picked = (board: board, side: _lab.position.turn(board), role: role);
    setState(() => _picked = _picked == picked ? null : picked);
  }

  void _touched(BoardNumber board, Square square) {
    if (!mounted) return;
    final picked = _stillPicked(_lab.position);
    if (picked == null) return;
    setState(() => _picked = null);
    if (picked.board == board) {
      _lab.play(board, DropMove(to: square, role: picked.role).uci);
    }
  }

  void _moved(BoardNumber board, Move move) {
    if (!mounted) return;
    final from = _draggingFrom;
    if (move is DropMove && from != null && from != board) return;
    setState(() => _picked = null);
    _lab.play(board, move.uci);
  }

  /// The pick, while it can still be dropped: the move or a step may have
  /// taken the turn or the piece away.
  _Picked? _stillPicked(TablePosition position) {
    final picked = _picked;
    if (picked == null) return null;
    final board = position.board(picked.board);
    final has = board.pockets!.of(board.turn, picked.role) > 0;
    return has && board.turn == picked.side ? picked : null;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_lab, widget.engine]),
      builder: (context, _) {
        final picked = _stillPicked(_lab.position);
        final shown = _lab.single ? [BoardNumber.one] : BoardNumber.values;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final board in shown) ...[
              if (board == BoardNumber.two) const SizedBox(width: labBoardGap),
              _BoardColumn(
                lab: _lab,
                engine: widget.engine,
                board: board,
                size: widget.boardSize,
                picked: picked?.board == board ? picked!.role : null,
                onPick: (role) => _pick(board, role),
                onTouched: (square) => _touched(board, square),
                onMove: (move) => _moved(board, move),
                onDrag: (on) => _draggingFrom = on ? board : null,
              ),
            ],
          ],
        );
      },
    );
  }
}

class _BoardColumn extends StatelessWidget {
  const _BoardColumn({
    required this.lab,
    required this.engine,
    required this.board,
    required this.size,
    required this.picked,
    required this.onPick,
    required this.onTouched,
    required this.onMove,
    required this.onDrag,
  });

  final BughouseLab lab;
  final LabEngine engine;
  final BoardNumber board;
  final double size;
  final Role? picked;
  final ValueChanged<Role> onPick;
  final ValueChanged<Square> onTouched;
  final ValueChanged<Move> onMove;
  final ValueChanged<bool> onDrag;

  @override
  Widget build(BuildContext context) {
    final bottom = lab.bottom(board);
    Widget seat(Side side) => _SeatRow(
      lab: lab,
      board: board,
      side: side,
      square: size / 8,
      picked: picked,
      onPick: onPick,
      onDrag: onDrag,
    );
    return Listener(
      onPointerDown: (_) => lab.focusOn(board),
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!lab.single)
              SizedBox(
                height: labBoardLabelHeight,
                child: Text(
                  board.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            seat(bottom.opposite),
            Listener(
              onPointerSignal: _wheel,
              child: ValueListenableBuilder(
                valueListenable: lab.preview,
                builder: (context, preview, _) {
                  final pointed = preview?[board];
                  final rows = pointed == null
                      ? engine.rowsOn(board)
                      : const <EngineRow>[];
                  return _Board(
                    key: ValueKey(board),
                    position: lab.position.board(board),
                    size: size,
                    orientation: bottom,
                    lastMove: lab.line.current(board)?.uci,
                    shapes: _shapes(pointed, rows),
                    arrows: [
                      if (pointed != null) ?_arrow(pointed, best: true),
                      for (final (i, row) in rows.indexed)
                        if (row.move case final uci?
                            when i == 0 || row.shift < engineArrowCutoff)
                          ?_arrow(uci, best: i == 0, shift: row.shift),
                    ],
                    onMove: onMove,
                    onTouched: onTouched,
                  );
                },
              ),
            ),
            seat(bottom),
            if (!lab.single) ...[
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
                child: BoardLineRows(
                  lab: lab,
                  lines: engine.lines,
                  board: board,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The wheel steps this board: down a move forward, up a move back, as
  /// on lila; the column around it does not scroll.
  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      lab.stepOn(board, event.scrollDelta.dy > 0 ? 1 : -1);
    });
  }

  /// A move pointed at in a row, or one of the engine's best, as lila's
  /// engine arrow: pale blue for the choice, grey and thinner the further
  /// [shift] behind it. A drop has no arrow.
  EngineArrow? _arrow(String uci, {required bool best, double shift = 0}) =>
      switch (Move.parse(uci)) {
        NormalMove(:final from, :final to) => (
          from: from,
          to: to,
          colour: best ? engineBestArrow : engineOtherArrow,
          width: best ? engineArrowWidth : (12 - shift * 50).roundToDouble(),
        ),
        _ => null,
      };

  /// Drops pointed at or among the engine's best as lila draws them: a ring
  /// on the square in the arrow's colour, pale blue for the choice and grey
  /// for the rest, with the piece inside it; and while a reserve piece is
  /// picked up, the squares it may go to.
  Set<Shape> _shapes(String? pointed, List<EngineRow> rows) {
    final position = lab.position.board(board);
    List<Shape> drop(String uci, {required bool best}) =>
        switch (Move.parse(uci)) {
          DropMove(:final to, :final role) => [
            Circle(color: best ? engineBestArrow : engineOtherArrow, orig: to),
            PieceShape(
              orig: to,
              piece: Piece(color: position.turn, role: role),
              pieceAssets: PieceSet.cburnettAssets,
              opacity: best ? 0.6 : 0.4,
              scale: 0.8,
            ),
          ],
          _ => const [],
        };
    return {
      if (pointed != null) ...drop(pointed, best: true),
      for (final (i, row) in rows.indexed)
        if (row.move case final uci?
            when i == 0 || row.shift < engineArrowCutoff)
          ...drop(uci, best: i == 0),
      if (picked case final role?)
        for (final square in position.legalDrops.squares)
          if (position.isLegal(DropMove(to: square, role: role)))
            Circle(color: labHintColor, orig: square, scale: 0.5),
    };
  }
}

/// A player's hand as lila's crazyhouse pocket: five slots, each the size
/// of a board square, in a grey well beside the turn dot and, with both
/// boards shown, the seat's letter. Pieces held show in full with their
/// count; empty slots stay in place, faint. Only the player on move can
/// drop, by click then square, or drag. While the pointer is over a slot
/// a − and a + in its corners take one of that piece away or add one.
class _SeatRow extends StatelessWidget {
  const _SeatRow({
    required this.lab,
    required this.board,
    required this.side,
    required this.square,
    required this.picked,
    required this.onPick,
    required this.onDrag,
  });

  final BughouseLab lab;
  final BoardNumber board;
  final Side side;

  /// A square of the board, the size of a hand's piece.
  final double square;
  final Role? picked;
  final ValueChanged<Role> onPick;
  final ValueChanged<bool> onDrag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final position = lab.position;
    final seat = Seat.of(board, side);
    final toMove = position.turn(board) == side;
    final pockets = position.board(board).pockets!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: labSeatInset),
      child: Row(
        children: [
          TurnDot(side: side, shown: toMove),
          const SizedBox(width: Space.s),
          if (!lab.single)
            SizedBox(
              width: Space.l,
              child: Text(
                seat.letter,
                style: TextStyle(
                  color: toMove ? scheme.onSurface : scheme.onSurfaceVariant,
                  fontWeight: toMove ? FontWeight.w600 : null,
                ),
              ),
            ),
          PocketWell(
            pockets: pockets,
            side: side,
            seat: seat,
            owner: lab.single
                ? (side == Side.white ? 'White' : 'Black')
                : 'Player ${seat.letter}',
            square: square,
            live: toMove,
            picked: picked,
            onPick: onPick,
            onDrag: onDrag,
            onStep: (role, by) => lab.adjustHand(board, side, role, by),
          ),
          // As tall as the hand, which the board's size allows for.
          Expanded(
            child: SizedBox(
              height: square,
              child: _SeatPlayer(
                name: lab.game?.name(seat),
                rating: lab.game?.rating(seat),
                clock: lab.timeLeft(seat),
                toMove: toMove,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Who sits in a seat and what their clock reads with the boards as they
/// are, at the end of the hand's row: the name over the clock, or beside it
/// when the hand is too short for two lines, the clock of the player on move
/// in full ink. Both from the game's BPGN; a line made here has neither,
/// and the room stays empty. A name too long for the room is cut short and
/// whole on hover; the clock is never cut, and in a room too narrow for it
/// it is drawn smaller.
class _SeatPlayer extends StatelessWidget {
  const _SeatPlayer({
    required this.name,
    required this.rating,
    required this.clock,
    required this.toMove,
  });

  final String? name;
  final String? rating;
  final Duration? clock;
  final bool toMove;

  @override
  Widget build(BuildContext context) {
    final name = this.name;
    final clock = this.clock;
    if (name == null && clock == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final who = [?name, ?rating].join(' ');
    final player = name == null
        ? null
        : Tooltip(
            message: who,
            child: Text.rich(
              TextSpan(
                text: name,
                children: [
                  if (rating != null)
                    TextSpan(
                      text: ' $rating',
                      style: TextStyle(color: muted),
                    ),
                ],
              ),
              style: bodySmallInk(theme),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          );
    Widget? time(double width) => clock == null
        ? null
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: math.max(0, width)),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                clockText(clock),
                style: labClockText.copyWith(
                  color: toMove ? theme.colorScheme.onSurface : muted,
                ),
                maxLines: 1,
                softWrap: false,
                semanticsLabel: '${name ?? 'Clock'} ${clockText(clock)}',
              ),
            ),
          );
    return Padding(
      padding: const EdgeInsets.only(left: Space.s),
      child: LayoutBuilder(
        builder: (context, room) => room.maxHeight < labSeatTwoLines
            ? Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: player,
                    ),
                  ),
                  if (player != null && clock != null)
                    const SizedBox(width: Space.s),
                  ?time(room.maxWidth - (player == null ? 0 : Space.s)),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [?player, ?time(room.maxWidth)],
              ),
      ),
    );
  }
}

/// One board of the table on chessground, with drops. The board's own
/// controller keeps the pieces, so it is rebuilt only when the position or
/// the last move changes.
class _Board extends StatefulWidget {
  const _Board({
    super.key,
    required this.position,
    required this.size,
    required this.orientation,
    required this.lastMove,
    required this.shapes,
    required this.arrows,
    required this.onMove,
    required this.onTouched,
  });

  final Crazyhouse position;
  final double size;
  final Side orientation;
  final String? lastMove;
  final Set<Shape> shapes;

  /// The engine's arrows, under any the user draws.
  final List<EngineArrow> arrows;
  final ValueChanged<Move> onMove;
  final ValueChanged<Square> onTouched;

  @override
  State<_Board> createState() => _BoardState();
}

class _BoardState extends State<_Board> {
  late final _controller = ChessboardController(game: _game());

  /// What the user drew on this position, and the shape under a right-drag.
  List<BoardShape> _drawn = const [];
  BoardShape? _drawing;

  GameData _game() {
    final position = widget.position;
    return GameData(
      fen: position.fen,
      playerSide: PlayerSide.both,
      sideToMove: position.turn,
      validMoves: makeLegalMoves(position),
      validDropSquares: position.legalDrops.squares.toSet(),
      lastMove: widget.lastMove == null ? null : Move.parse(widget.lastMove!),
      kingSquareInCheck: position.isCheck
          ? position.board.kingOf(position.turn)
          : null,
    );
  }

  @override
  void didUpdateWidget(_Board old) {
    super.didUpdateWidget(old);
    if (old.position != widget.position || old.lastMove != widget.lastMove) {
      _controller.updatePosition(_game());
    }
    if (old.position != widget.position) {
      _drawn = const [];
      _drawing = null;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = BoardTheme.of(
      context,
    ).settings(coordinates: true).copyWith(enableDrops: true);
    final shown = [..._drawn, ?_drawing];
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => setState(() => _drawing = null),
      child: Stack(
        children: [
          Chessboard(
            size: widget.size,
            controller: _controller,
            orientation: widget.orientation,
            settings: settings,
            shapes: {
              ...widget.shapes,
              for (final shape in shown)
                if (shape.isCircle) circleShape(shape),
            },
            onMove: (move, {viaDragAndDrop}) => widget.onMove(move),
            onTouchedSquare: widget.onTouched,
          ),
          // Over the pieces, as on lila, and away while a pawn waits for
          // the piece it becomes.
          Positioned.fill(
            child: IgnorePointer(
              child: ValueListenableBuilder(
                // ignore: invalid_use_of_internal_member
                valueListenable: _controller.pendingPromotionNotifier,
                builder: (context, promotion, _) => promotion != null
                    ? const SizedBox.shrink()
                    : BoardArrows(
                        engine: widget.arrows,
                        arrows: [
                          for (final shape in shown)
                            if (!shape.isCircle) shape,
                        ],
                        drawing: _drawing?.isCircle ?? true ? null : _drawing,
                        orientation: widget.orientation,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The right button starts a shape on the square under it; the left one
  /// takes the drawn ones away, as a click does on lila, and plays on.
  void _down(PointerDownEvent event) {
    if (event.buttons == kSecondaryButton) {
      final square = squareAt(
        event.localPosition,
        widget.size,
        widget.orientation,
      );
      if (square == null) return;
      setState(() => _drawing = BoardShape.circle(square, heldShapeColour()));
    } else if (event.buttons == kPrimaryButton && _drawn.isNotEmpty) {
      setState(() => _drawn = const []);
    }
  }

  void _move(PointerMoveEvent event) {
    final drawing = _drawing;
    final square = squareAt(
      event.localPosition,
      widget.size,
      widget.orientation,
    );
    if (drawing == null || square == null || square == drawing.to) return;
    setState(() => _drawing = BoardShape(drawing.from, square, drawing.colour));
  }

  void _up() {
    final drawn = _drawing;
    if (drawn == null) return;
    setState(() {
      _drawing = null;
      _drawn = withShapeDrawn(_drawn, drawn);
    });
  }
}
