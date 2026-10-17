import 'dart:async';

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chess/bughouse/table.dart';
import '../../chess/bughouse/table_line.dart';
import '../../ui/action_context_menu.dart';
import '../../ui/app_action.dart';
import '../../ui/app_keys.dart';
import '../../ui/move_notation.dart';
import '../../ui/theme.dart';
import 'bughouse_lab.dart';
import 'pocket.dart';

/// The boards on screen, each with its two players' hands: board 1 alone,
/// or both side by side, each with its own move list and step buttons.
///
/// Board 1 has A (White) and C (Black), board 2 D (White) and B (Black); our
/// team's colour is at the bottom of board 1 unless the boards are flipped.
/// A piece moves by click or drag; a hand's piece is dragged onto a square,
/// or clicked and then its square clicked, the squares it may go to ringed.
/// The + above and − below each hand's piece add one or take one away.
class TableBoards extends StatefulWidget {
  const TableBoards({super.key, required this.lab, required this.boardSize});

  final BughouseLab lab;
  final double boardSize;

  @override
  State<TableBoards> createState() => _TableBoardsState();
}

/// A reserve piece picked up by a click, for the next square clicked.
typedef _Picked = ({BoardNumber board, Side side, Role role});

class _TableBoardsState extends State<TableBoards> {
  _Picked? _picked;

  BughouseLab get _lab => widget.lab;

  @override
  void initState() {
    super.initState();
    _lab.addListener(_tableChanged);
  }

  @override
  void didUpdateWidget(TableBoards oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lab != _lab) {
      oldWidget.lab.removeListener(_tableChanged);
      _lab.addListener(_tableChanged);
      _picked = null;
    }
  }

  @override
  void dispose() {
    _lab.removeListener(_tableChanged);
    super.dispose();
  }

  void _tableChanged() {
    if (!mounted || _picked == null || _stillPicked(_lab.position) != null) {
      return;
    }
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
      listenable: _lab,
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
      lab: lab,
      board: board,
      side: side,
      square: size / 8,
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
            if (!lab.single)
              SizedBox(
                height: labBoardLabelHeight,
                child: Text(
                  board.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
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
            if (!lab.single) BoardMoves(lab: lab, board: board),
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

/// A player's hand as lila's crazyhouse pocket: five slots, each the size
/// of a board square, in a grey well beside the turn dot and, with both
/// boards shown, the seat's letter. Pieces held show in full with their
/// count; empty slots stay in place, faint. Only the player on move can
/// drop, by click then square, or drag. A + above each slot adds one of
/// that piece and a − below takes one away.
class _SeatRow extends StatelessWidget {
  const _SeatRow({
    required this.lab,
    required this.board,
    required this.side,
    required this.square,
    required this.picked,
    required this.onPick,
  });

  final BughouseLab lab;
  final BoardNumber board;
  final Side side;

  /// A square of the board, the size of a hand's piece.
  final double square;
  final Role? picked;
  final ValueChanged<Role> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final position = lab.position;
    final seat = Seat.of(board, side);
    final toMove = position.turn(board) == side;
    final pockets = position.board(board).pockets!;
    Widget steps(int delta) => Row(
      children: [
        for (final role in reserveRoles)
          _HandStep(
            side: side,
            role: role,
            delta: delta,
            width: square,
            enabled: delta > 0
                ? pockets.of(side, role) < handLimit
                : pockets.of(side, role) > 0,
            onPressed: () => lab.adjustHand(board, side, role, delta),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: labSeatPadding / 2),
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
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              steps(1),
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
              ),
              steps(-1),
            ],
          ),
        ],
      ),
    );
  }
}

/// One + or − over a hand's slot.
class _HandStep extends StatelessWidget {
  const _HandStep({
    required this.side,
    required this.role,
    required this.delta,
    required this.width,
    required this.enabled,
    required this.onPressed,
  });

  final Side side;
  final Role role;
  final int delta;
  final double width;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colour = side == Side.white ? 'White' : 'Black';
    final tip = delta > 0
        ? 'One more ${role.name} for $colour'
        : 'One ${role.name} fewer for $colour';
    return SizedBox(
      width: width,
      height: labStepHeight,
      child: IconButton(
        tooltip: tip,
        onPressed: enabled ? onPressed : null,
        icon: Icon(delta > 0 ? Icons.add : Icons.remove),
        iconSize: IconSize.action,
        style: IconButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          fixedSize: Size(width, labStepHeight),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Space.xs),
          ),
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
/// Under a board the list is a few rows tall; with [fill] it takes the
/// height its parent leaves.
class BoardMoves extends StatelessWidget {
  const BoardMoves({
    super.key,
    required this.lab,
    required this.board,
    this.fill = false,
  });

  final BughouseLab lab;
  final BoardNumber board;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final line = lab.line;
    final upto = line.upto(board);
    final total = line.of(board).length;
    final scheme = Theme.of(context).colorScheme;
    final focused = lab.focus == board && !lab.single;
    final list = Container(
      height: fill ? null : labMoveListHeight,
      decoration: BoxDecoration(
        border: Border.symmetric(
          horizontal: BorderSide(
            color: focused ? scheme.primary : scheme.outline,
          ),
        ),
      ),
      child: _MoveRows(lab: lab, board: board),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (fill) Expanded(child: list) else list,
        const SizedBox(height: Space.xs),
        Row(
          children: [
            _step(
              Icons.first_page,
              AppKey.firstMove.tip('First move'),
              upto > 0,
              0,
            ),
            _step(
              Icons.chevron_left,
              AppKey.stepBack.tip('Back'),
              upto > 0,
              upto - 1,
            ),
            _step(
              Icons.chevron_right,
              AppKey.stepForward.tip('Forward'),
              upto < total,
              upto + 1,
            ),
            _step(
              Icons.last_page,
              AppKey.lastMove.tip('Last move'),
              upto < total,
              total,
            ),
          ],
        ),
      ],
    );
  }

  Widget _step(IconData icon, String tip, bool enabled, int to) => IconButton(
    icon: Icon(icon, size: IconSize.action),
    tooltip: lab.single ? tip : '$tip, ${board.label.toLowerCase()}',
    visualDensity: VisualDensity.compact,
    onPressed: enabled ? () => lab.go(board, to) : null,
  );
}

/// The move list, kept scrolled so the current move is in view.
class _MoveRows extends StatefulWidget {
  const _MoveRows({required this.lab, required this.board});

  final BughouseLab lab;
  final BoardNumber board;

  @override
  State<_MoveRows> createState() => _MoveRowsState();
}

class _MoveRowsState extends State<_MoveRows> {
  final _scroll = ScrollController();

  BughouseLab get lab => widget.lab;
  BoardNumber get board => widget.board;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// After the frame, the least scroll that shows the row of the current
  /// move.
  void _reveal(int row) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      final top = row * labMoveRowHeight;
      final bottom = top + labMoveRowHeight - position.viewportDimension;
      final offset = position.pixels.clamp(bottom, top);
      if (offset != position.pixels) {
        _scroll.jumpTo(offset.clamp(0, position.maxScrollExtent));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final line = lab.line;
    final moves = line.of(board);
    final scheme = Theme.of(context).colorScheme;
    final start = handChangeText(line.handChanges(board, 0));
    if (moves.isEmpty && start.isEmpty) return const SizedBox.expand();
    final lead = start.isEmpty ? 0 : 1;
    final rows = _pairs(moves);
    final upto = line.upto(board);
    final at = rows.indexWhere(
      (row) => [row.white, row.black].any((h) => h?.index == upto - 1),
    );
    _reveal(at < 0 ? 0 : at + lead);
    return ListView.builder(
      controller: _scroll,
      itemExtent: labMoveRowHeight,
      itemCount: rows.length + lead,
      itemBuilder: (context, i) {
        if (i < lead) {
          return Row(
            children: [
              const SizedBox(width: labMoveNumberWidth),
              Expanded(
                child: _MoveToken(
                  text: 'Start',
                  edit: start,
                  tip: 'Hands edited at the start',
                  current: upto == 0,
                  future: false,
                  onTap: () => lab.go(board, 0),
                ),
              ),
            ],
          );
        }
        final row = rows[i - lead];
        return Row(
          children: [
            SizedBox(
              width: labMoveNumberWidth,
              child: Text(
                '${row.number}.',
                style: monoText.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            for (final half in [row.white, row.black])
              Expanded(
                child: half == null
                    ? const SizedBox.shrink()
                    : _MoveToken(
                        text: displaySan(context, half.move.san),
                        edit: handChangeText(
                          line.handChanges(board, half.index + 1),
                        ),
                        tip:
                            'Player '
                            '${Seat.of(board, half.move.side).letter}',
                        current: half.index == upto - 1,
                        future: half.index >= upto,
                        onTap: () => lab.go(board, half.index + 1),
                        menu: () => moveMenu(lab, half.move),
                      ),
              ),
          ],
        );
      },
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

/// What a move in a board's list offers on the right button, as the
/// workspace's move list does: the line up to it as PGN (crazyhouse with
/// one board, BPGN with two), the board's FEN after it, with two boards the
/// dual FEN, and taking it out with the board's later moves.
List<AppAction> moveMenu(BughouseLab lab, LineMove move) {
  final after = lab.positionAfter(move);
  return [
    AppAction('Copy line PGN', () => _copy(lab.linePgnThrough(move))),
    AppAction(
      'Copy FEN',
      after == null ? null : () => _copy(after.board(move.board).fen),
    ),
    if (!lab.single)
      AppAction(
        'Copy dual FEN',
        after == null ? null : () => _copy(after.dualFen),
      ),
    AppAction('Delete from here', () => lab.deleteFrom(move)),
  ];
}

void _copy(String text) =>
    unawaited(Clipboard.setData(ClipboardData(text: text)));
typedef _MovePair = ({int number, _Half? white, _Half? black});

/// A move, or the start, with the hand edit made after it in muted ink.
class _MoveToken extends StatelessWidget {
  const _MoveToken({
    required this.text,
    required this.edit,
    required this.tip,
    required this.current,
    required this.future,
    required this.onTap,
    this.menu,
  });

  final String text;

  /// The hands' change noted after the move, `+N −p`, or empty.
  final String edit;
  final String tip;
  final bool current;
  final bool future;
  final VoidCallback onTap;

  /// What the right button offers for this move; null for the start.
  final List<AppAction> Function()? menu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final menu = this.menu;
    return Tooltip(
      message: edit.isEmpty ? tip : '$tip\nHands edited after: $edit',
      waitDuration: previewDelay,
      child: InkWell(
        onTap: onTap,
        onSecondaryTapUp: menu == null
            ? null
            : (details) => unawaited(
                showActionContextMenu(context, details.globalPosition, menu()),
              ),
        child: Container(
          padding: moveTokenPadding,
          color: current ? scheme.surfaceContainerHighest : null,
          child: Text.rich(
            TextSpan(
              text: text,
              children: [
                if (edit.isNotEmpty)
                  TextSpan(
                    text: ' $edit',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
