import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../chess/bughouse/table.dart';
import '../../chess/bughouse/table_line.dart';
import '../../ui/theme.dart';
import 'bughouse_lab.dart';

/// Both boards side by side, each with its two players and their
/// reserves, its own move list and its step buttons.
///
/// Board 1 has A (White) and C (Black), board 2 D (White) and B (Black); our
/// team's colour is at the bottom of board 1 unless the boards are flipped.
/// A piece moves by click or drag; a reserve piece is dragged onto a square,
/// or clicked and then its square clicked, the squares it may go to ringed.
class TableBoards extends StatefulWidget {
  const TableBoards({super.key, required this.lab, required this.boardSize});

  final BughouseLab lab;
  final double boardSize;

  @override
  State<TableBoards> createState() => _TableBoardsState();
}

/// A reserve piece picked up by a click, for the next square clicked.
typedef _Picked = ({BoardNumber board, Role role});

class _TableBoardsState extends State<TableBoards> {
  _Picked? _picked;

  BughouseLab get _lab => widget.lab;

  void _pick(BoardNumber board, Role role) {
    final picked = (board: board, role: role);
    setState(() => _picked = _picked == picked ? null : picked);
  }

  void _touched(BoardNumber board, Square square) {
    final picked = _picked;
    if (picked == null) return;
    setState(() => _picked = null);
    if (picked.board == board) {
      _lab.play(board, DropMove(to: square, role: picked.role).uci);
    }
  }

  void _moved(BoardNumber board, Move move) {
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
    return has ? picked : null;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _lab,
      builder: (context, _) {
        final picked = _stillPicked(_lab.position);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final board in BoardNumber.values) ...[
              if (board == BoardNumber.two) const SizedBox(width: labBoardGap),
              _BoardColumn(
                lab: _lab,
                board: board,
                size: widget.boardSize,
                picked: picked?.board == board ? picked!.role : null,
                onPick: (role) => _pick(board, role),
                onTouched: (square) => _touched(board, square),
                onMove: (move) => _moved(board, move),
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
    required this.board,
    required this.size,
    required this.picked,
    required this.onPick,
    required this.onTouched,
    required this.onMove,
  });

  final BughouseLab lab;
  final BoardNumber board;
  final double size;
  final Role? picked;
  final ValueChanged<Role> onPick;
  final ValueChanged<Square> onTouched;
  final ValueChanged<Move> onMove;

  @override
  Widget build(BuildContext context) {
    final bottom = lab.bottom(board);
    Widget seat(Side side) => _SeatRow(
      position: lab.position,
      board: board,
      side: side,
      picked: picked,
      onPick: onPick,
    );
    return Listener(
      onPointerDown: (_) => lab.focusOn(board),
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            seat(bottom.opposite),
            ValueListenableBuilder(
              valueListenable: lab.preview,
              builder: (context, preview, _) => _Board(
                key: ValueKey(board),
                position: lab.position.board(board),
                size: size,
                orientation: bottom,
                lastMove: lab.line.current(board)?.uci,
                shapes: _shapes(preview?[board]),
                onMove: onMove,
                onTouched: onTouched,
              ),
            ),
            seat(bottom),
            BoardMoves(lab: lab, board: board),
          ],
        ),
      ),
    );
  }

  /// The move pointed at in a table, as an arrow or, for a drop, the piece
  /// faint on its square; and while a reserve piece is picked up, the
  /// squares it may go to.
  Set<Shape> _shapes(String? pointed) {
    final position = lab.position.board(board);
    return {
      if (pointed != null)
        switch (Move.parse(pointed)) {
          NormalMove(:final from, :final to) => Arrow(
            color: labHintColor,
            orig: from,
            dest: to,
          ),
          DropMove(:final to, :final role) => PieceShape(
            color: labHintColor,
            orig: to,
            piece: Piece(color: position.turn, role: role),
            pieceAssets: PieceSet.cburnettAssets,
          ),
          null => null,
        },
      if (picked case final role?)
        for (final square in position.legalDrops.squares)
          if (position.isLegal(DropMove(to: square, role: role)))
            Circle(color: labHintColor, orig: square, scale: 0.5),
    }.nonNulls.toSet();
  }
}

/// One player beside a board: the turn dot, `Player A`, then the reserve,
/// each piece they hold with its count. A reserve piece of the player on
/// move is dragged onto the board, or clicked to pick it up.
class _SeatRow extends StatelessWidget {
  const _SeatRow({
    required this.position,
    required this.board,
    required this.side,
    required this.picked,
    required this.onPick,
  });

  final TablePosition position;
  final BoardNumber board;
  final Side side;
  final Role? picked;
  final ValueChanged<Role> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final seat = Seat.of(board, side);
    final toMove = position.turn(board) == side;
    final pockets = position.board(board).pockets!;
    return SizedBox(
      height: labSeatHeight,
      child: Row(
        children: [
          _TurnDot(side: side, shown: toMove),
          const SizedBox(width: Space.s),
          Text(
            'Player ${seat.letter}',
            style: TextStyle(
              color: toMove ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: Space.s),
          for (final role in reserveRoles)
            if (pockets.of(side, role) case final count when count > 0)
              _ReservePiece(
                key: ValueKey(('reserve', seat, role)),
                piece: Piece(color: side, role: role),
                count: count,
                seat: seat,
                live: toMove,
                picked: toMove && picked == role,
                onPick: () => onPick(role),
              ),
        ],
      ),
    );
  }
}

class _TurnDot extends StatelessWidget {
  const _TurnDot({required this.side, required this.shown});

  final Side side;
  final bool shown;

  @override
  Widget build(BuildContext context) => Visibility.maintain(
    visible: shown,
    child: Tooltip(
      message: side == Side.white ? 'White to move' : 'Black to move',
      child: Container(
        width: labTurnDot,
        height: labTurnDot,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: side == Side.white ? labWhiteDot : labBlackDot,
          border: side == Side.black
              ? Border.all(color: labBlackDotRing)
              : null,
        ),
      ),
    ),
  );
}

class _ReservePiece extends StatelessWidget {
  const _ReservePiece({
    super.key,
    required this.piece,
    required this.count,
    required this.seat,
    required this.live,
    required this.picked,
    required this.onPick,
  });

  final Piece piece;
  final int count;
  final Seat seat;

  /// Whether its player is on move, so it may be dropped now.
  final bool live;
  final bool picked;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = PieceWidget(
      piece: piece,
      size: labReservePiece,
      pieceAssets: PieceSet.cburnettAssets,
    );
    final face = Container(
      padding: const EdgeInsets.only(right: Space.xs),
      decoration: BoxDecoration(
        border: Border.all(color: picked ? scheme.primary : Colors.transparent),
        borderRadius: BorderRadius.circular(Space.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [image, Text('$count')],
      ),
    );
    final label = 'Player ${seat.letter}: $count ${piece.role.name} in reserve';
    if (!live) return Semantics(label: label, child: face);
    return Semantics(
      label: label,
      button: true,
      child: Draggable<Piece>(
        data: piece,
        feedback: image,
        childWhenDragging: face,
        child: InkWell(onTap: onPick, child: face),
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
    required this.onMove,
    required this.onTouched,
  });

  final Crazyhouse position;
  final double size;
  final Side orientation;
  final String? lastMove;
  final Set<Shape> shapes;
  final ValueChanged<Move> onMove;
  final ValueChanged<Square> onTouched;

  @override
  State<_Board> createState() => _BoardState();
}

class _BoardState extends State<_Board> {
  late final _controller = ChessboardController(game: _game());

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
    return Chessboard(
      size: widget.size,
      controller: _controller,
      orientation: widget.orientation,
      settings: settings,
      shapes: widget.shapes,
      onMove: (move, {viaDragAndDrop}) => widget.onMove(move),
      onTouchedSquare: widget.onTouched,
    );
  }
}

/// A board's own moves, numbered as that board counts them, the current
/// one marked and the ones stepped past faint, with the four step buttons.
class BoardMoves extends StatelessWidget {
  const BoardMoves({super.key, required this.lab, required this.board});

  final BughouseLab lab;
  final BoardNumber board;

  @override
  Widget build(BuildContext context) {
    final line = lab.line;
    final upto = line.upto(board);
    final total = line.of(board).length;
    final scheme = Theme.of(context).colorScheme;
    final focused = lab.focus == board;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: labMoveListHeight,
          decoration: BoxDecoration(
            border: Border.symmetric(
              horizontal: BorderSide(
                color: focused ? scheme.primary : scheme.outline,
              ),
            ),
          ),
          child: _MoveRows(lab: lab, board: board),
        ),
        const SizedBox(height: Space.xs),
        Row(
          children: [
            _step(Icons.first_page, 'First move (Home)', upto > 0, 0),
            _step(Icons.chevron_left, 'Back (←)', upto > 0, upto - 1),
            _step(Icons.chevron_right, 'Forward (→)', upto < total, upto + 1),
            _step(Icons.last_page, 'Last move (End)', upto < total, total),
          ],
        ),
      ],
    );
  }

  Widget _step(IconData icon, String tip, bool enabled, int to) => IconButton(
    icon: Icon(icon, size: IconSize.action),
    tooltip: '$tip, ${board.label.toLowerCase()}',
    visualDensity: VisualDensity.compact,
    onPressed: enabled ? () => lab.go(board, to) : null,
  );
}

class _MoveRows extends StatelessWidget {
  const _MoveRows({required this.lab, required this.board});

  final BughouseLab lab;
  final BoardNumber board;

  @override
  Widget build(BuildContext context) {
    final moves = lab.line.of(board);
    final scheme = Theme.of(context).colorScheme;
    if (moves.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Space.xs),
        child: Text(
          'No moves yet',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final rows = _pairs(moves);
    final upto = lab.line.upto(board);
    return ListView.builder(
      reverse: false,
      itemCount: rows.length,
      itemBuilder: (context, i) => Row(
        children: [
          SizedBox(
            width: labMoveNumberWidth,
            child: Text(
              '${rows[i].number}.',
              style: monoText.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          for (final half in [rows[i].white, rows[i].black])
            Expanded(
              child: half == null
                  ? const SizedBox.shrink()
                  : _MoveToken(
                      move: half.move,
                      current: half.index == upto - 1,
                      future: half.index >= upto,
                      onTap: () => lab.go(board, half.index + 1),
                    ),
            ),
        ],
      ),
    );
  }

  /// The moves two to a row, White's then Black's, a row starting with
  /// Black's move when the board began with Black to move.
  static List<_MovePair> _pairs(List<LineMove> moves) {
    final rows = <_MovePair>[];
    for (final (i, move) in moves.indexed) {
      final half = (move: move, index: i);
      if (move.side == Side.white || rows.isEmpty || rows.last.black != null) {
        rows.add((
          number: move.number,
          white: move.side == Side.white ? half : null,
          black: move.side == Side.black ? half : null,
        ));
      } else {
        final last = rows.removeLast();
        rows.add((number: last.number, white: last.white, black: half));
      }
    }
    return rows;
  }
}

typedef _Half = ({LineMove move, int index});
typedef _MovePair = ({int number, _Half? white, _Half? black});

class _MoveToken extends StatelessWidget {
  const _MoveToken({
    required this.move,
    required this.current,
    required this.future,
    required this.onTap,
  });

  final LineMove move;
  final bool current;
  final bool future;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final seat = Seat.of(move.board, move.side);
    return Tooltip(
      message: 'Player ${seat.letter}',
      waitDuration: previewDelay,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: moveTokenPadding,
          color: current ? scheme.surfaceContainerHighest : null,
          child: Text(
            move.san,
            style: monoText.copyWith(
              color: current
                  ? scheme.primary
                  : future
                  ? scheme.onSurfaceVariant
                  : scheme.onSurface,
              fontWeight: current ? FontWeight.w600 : null,
            ),
          ),
        ),
      ),
    );
  }
}
