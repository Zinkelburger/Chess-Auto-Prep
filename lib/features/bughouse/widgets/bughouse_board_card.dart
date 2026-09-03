import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/app_messages.dart';
import '../../../utils/chess_utils.dart' show parseSquare;
import '../../../widgets/chess_board_widget.dart';
import '../../../widgets/common/piece_image.dart';
import '../controllers/bughouse_controller.dart';
import '../models/bughouse_state.dart';
import 'bughouse_move_list.dart';

/// One of the two boards, with everything that belongs to it stacked around it.
///
/// Top to bottom: the far player, their reserve, the board, the near player's
/// reserve, the near player, then that board's own movetext. Four things about
/// bughouse decide that order.
///
///   * The reserves are filled by the *other* board, so both boards and all
///     four reserves have to be on screen at once: that is how you see whether
///     a mate threat is actually available.
///   * A reserve belongs to a person, so it sits next to that person's row and
///     nowhere else. The seat letter lives in the row, not in the reserve —
///     a pocket should hold pieces and nothing else, or the letter reads as
///     one more thing in it.
///   * Four people play, and "white on board 2" does not name one of them.
///     A, B, C, D do, and the row says which of the four this is in words.
///   * Each board is its own game with its own move numbers, which is why the
///     movetext is under the board it belongs to rather than pooled in a panel
///     across the screen from both of them.
class BughouseBoardCard extends StatelessWidget {
  const BughouseBoardCard({
    super.key,
    required this.controller,
    required this.which,
  });

  final BughouseController controller;
  final BughouseBoard which;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final position = state.board(which);
    final flipped = controller.isFlipped(which);
    final topSide = flipped ? Side.white : Side.black;
    final bottomSide = flipped ? Side.black : Side.white;
    final last = controller.lastPlyOn(which);
    final recent = last == null ? <String>{} : _squaresOf(last.move);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _BoardHeader(controller: controller, which: which),
        const SizedBox(height: 6),
        _Seat(controller: controller, which: which, side: topSide),
        _PocketRow(controller: controller, which: which, side: topSide),
        const SizedBox(height: 6),
        AspectRatio(
          aspectRatio: 1,
          child: _BoardSurface(
            controller: controller,
            which: which,
            flipped: flipped,
            child: ChessBoardWidget(
              position: position,
              flipped: flipped,
              enableUserMoves: controller.mode == BughouseMode.play,
              recentMoveSquares: recent,
              annotations: controller.annotationsFor(which),
              highlightedSquares: {
                ..._dropTargets(),
                ...controller.hoveredSquares(which),
              },
              onSquareClicked: _onSquareClicked,
              onMove: (completed) {
                if (controller.mode != BughouseMode.play) return;
                final from = parseSquare(completed.from);
                final to = parseSquare(completed.to);
                if (from == null || to == null) return;
                controller.playMove(
                  which,
                  NormalMove(
                    from: from,
                    to: to,
                    promotion: _promotionOf(completed.uci),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 6),
        _PocketRow(controller: controller, which: which, side: bottomSide),
        _Seat(controller: controller, which: which, side: bottomSide),
        const SizedBox(height: 8),
        BughouseBoardMovetext(controller: controller, which: which),
      ],
    );
  }

  void _onSquareClicked(String algebraic) {
    final square = parseSquare(algebraic);
    if (square == null) return;
    controller.tryDropOn(which, square);
  }

  /// Where a held reserve piece may legally land, so picking one up shows its
  /// squares the way selecting a piece does.
  Set<String> _dropTargets() {
    final pending = controller.pendingDrop;
    if (pending == null || pending.board != which) return const {};
    final position = controller.state.board(which);
    if (position.turn != pending.side) return const {};
    final squares = <String>{};
    for (final square in Square.values) {
      if (position.isLegal(DropMove(to: square, role: pending.role))) {
        squares.add(square.name);
      }
    }
    return squares;
  }

  static Role? _promotionOf(String uci) {
    if (uci.length < 5) return null;
    return switch (uci[4]) {
      'q' => Role.queen,
      'r' => Role.rook,
      'b' => Role.bishop,
      'n' => Role.knight,
      _ => null,
    };
  }

  static Set<String> _squaresOf(Move move) => switch (move) {
    NormalMove(:final from, :final to) => {from.name, to.name},
    DropMove(:final to) => {to.name},
  };
}

/// Which board this is, and the one control that belongs to a board rather
/// than to the position: which way up it is drawn.
class _BoardHeader extends StatelessWidget {
  const _BoardHeader({required this.controller, required this.which});

  final BughouseController controller;
  final BughouseBoard which;

  @override
  Widget build(BuildContext context) {
    final last = controller.lastPlyOn(which);
    return Row(
      children: [
        Text(which.label.toUpperCase(), style: AppTextStyles.eyebrow),
        const SizedBox(width: 10),
        // The move that just landed here, which on two boards is two separate
        // questions — the whole-line cursor answers neither of them. Blank
        // rather than "no moves yet": the movetext under the board already
        // says that, and saying it twice reads as two different facts.
        Expanded(
          child: Text(
            last == null ? '' : '${last.numberLabel} ${last.san}',
            style: AppTextStyles.monoDense,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: "Copy ${which.label.toLowerCase()}'s moves",
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 24),
          icon: const Icon(Icons.copy),
          // Disabled rather than hidden: a control that appears with the
          // first move would shift the flip button sideways mid-game.
          onPressed: controller.history.movetextOn(which).isEmpty
              ? null
              : () => copyToClipboard(
                  context,
                  controller.history.movetextFor(which),
                  successMessage: '${which.label} moves copied',
                ),
        ),
        IconButton(
          tooltip: 'Draw ${which.label.toLowerCase()} the other way up',
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 24),
          icon: const Icon(Icons.swap_vert),
          onPressed: () => controller.toggleFlip(which),
        ),
      ],
    );
  }
}

/// One of the four people at the table: who they are, what colour they hold,
/// whether it is their move, and how much time they have left.
///
/// This is the row lichess puts a player's name in, and it is where the seat
/// letter belongs — attached to a person, beside their clock, rather than
/// tucked into the reserve strip where it competed with the pieces.
class _Seat extends StatelessWidget {
  const _Seat({
    required this.controller,
    required this.which,
    required this.side,
  });

  final BughouseController controller;
  final BughouseBoard which;
  final Side side;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final onMove = state.board(which).turn == side;
    final ours =
        state.seatLetter(which, side) == 'A' ||
        state.seatLetter(which, side) == 'C';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          _SeatBadge(
            letter: state.seatLetter(which, side),
            side: side,
            ours: ours,
            tooltip: state.seatDescription(which, side),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              state.seatRole(which, side),
              style: onMove
                  ? AppTextStyles.body.copyWith(fontWeight: FontWeight.w600)
                  : AppTextStyles.muted,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onMove)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Tooltip(
                message: 'To move',
                child: Icon(Icons.play_arrow, size: 13, color: AppColors.ink),
              ),
            ),
          _ClockBox(controller: controller, which: which, side: side),
        ],
      ),
    );
  }
}

/// `A` on a white or black chip — a seat letter and its colour in one glyph,
/// which is the pair a bughouse player actually needs to hold.
class _SeatBadge extends StatelessWidget {
  const _SeatBadge({
    required this.letter,
    required this.side,
    required this.ours,
    required this.tooltip,
  });

  final String letter;
  final Side side;
  final bool ours;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final white = side == Side.white;
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: white ? AppColors.sideWhite : AppColors.sideBlack,
          borderRadius: BorderRadius.circular(4),
          // Our two seats are outlined; theirs are not. One bit, and it is the
          // bit you scan for when the four rows all look alike.
          border: Border.all(
            color: ours ? AppColors.ink : AppColors.outline,
            width: ours ? 1.5 : 1,
          ),
        ),
        child: Text(
          letter,
          style: AppTextStyles.mono.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.0,
            color: white ? AppColors.onSideWhite : AppColors.ink,
          ),
        ),
      ),
    );
  }
}

/// One clock, typed as `m:ss` or as plain seconds.
///
/// In the seat row rather than in a settings panel, because a bughouse clock
/// is not a statistic: the diagonal relationship between the four of them is
/// what decides whether a team may sit, which is a *rule* input to the search.
/// Editing it where you read it is the difference between a knob you use and
/// one you forget is there.
class _ClockBox extends StatefulWidget {
  const _ClockBox({
    required this.controller,
    required this.which,
    required this.side,
  });

  final BughouseController controller;
  final BughouseBoard which;
  final Side side;

  @override
  State<_ClockBox> createState() => _ClockBoxState();
}

class _ClockBoxState extends State<_ClockBox> {
  late final TextEditingController _text = TextEditingController(
    text: BughouseClocks.format(_current),
  );
  final _focus = FocusNode();

  Duration get _current =>
      widget.controller.state.clocks.of(widget.which, widget.side);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ClockBox old) {
    super.didUpdateWidget(old);
    // Kept in step with the controller while nobody is typing — "new game" and
    // a loaded position both reset the clocks underneath this field.
    if (!_focus.hasFocus) {
      final text = BughouseClocks.format(_current);
      if (_text.text != text) _text.text = text;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message:
          'Time left. What decides whether a team may sit is the '
          'diagonal: your clock against your partner\'s opponent.',
      waitDuration: const Duration(milliseconds: 700),
      child: SizedBox(
        width: 58,
        child: TextField(
          controller: _text,
          focusNode: _focus,
          textAlign: TextAlign.right,
          style: AppTextStyles.mono.copyWith(fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: AppColors.surfaceInset,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 6,
              vertical: 5,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide.none,
            ),
          ),
          // Committed when the field is done with, not on every keystroke.
          // Each commit re-roots the whole line and restarts the search, and
          // the intermediate parses are wrong anyway — typing "3:00" passes
          // through "3", which reads as three seconds and flips the derived
          // clock stance on the way past.
          onSubmitted: (_) => _commit(),
        ),
      ),
    );
  }

  void _commit() {
    final current = _current;
    final parsed = BughouseClocks.tryParse(_text.text);
    if (parsed == null) {
      // Put the field back to the value that is actually in effect rather than
      // leaving unparseable text sitting there.
      _text.text = BughouseClocks.format(current);
      return;
    }
    _text.text = BughouseClocks.format(parsed);
    if (parsed == current) return;
    widget.controller.setClock(widget.which, widget.side, parsed);
  }
}

/// One side's reserve: five slots, pieces and counts, nothing else.
///
/// Always showing every slot is the point — an empty strip is what a bughouse
/// player scans to see what they *could* be sent — but an empty slot is drawn
/// faintly enough to read as absence rather than as a piece. Kings never
/// appear: they cannot be captured, so they never reach a reserve.
class _PocketRow extends StatelessWidget {
  const _PocketRow({
    required this.controller,
    required this.which,
    required this.side,
  });

  final BughouseController controller;
  final BughouseBoard which;
  final Side side;

  static const _reserveRoles = [
    Role.pawn,
    Role.knight,
    Role.bishop,
    Role.rook,
    Role.queen,
  ];

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final position = state.board(which);
    final pockets = position.pockets ?? Pockets.empty;
    final setup = controller.mode == BughouseMode.setup;
    final pending = controller.pendingDrop;
    // Dropping is only possible for the side actually on turn there, so the
    // other strip is shown but visibly inert.
    final droppable = setup || position.turn == side;

    return Tooltip(
      message: setup
          ? 'Click to add, right-click to remove'
          : droppable
          ? 'Drag a piece onto the board, or click it and then a square'
          : 'Not ${side.name}\'s turn on ${which.label.toLowerCase()}',
      waitDuration: const Duration(milliseconds: 600),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(4),
        ),
        // Packed tight and left-aligned, the way lichess draws a crazyhouse
        // pocket: the reserve reads as one clump, not as five columns
        // stretched across the board.
        child: Row(
          children: [
            for (final role in _reserveRoles)
              _PocketPiece(
                key: ValueKey(
                  'bughouse-pocket-${which.name}-${side.name}-${role.name}',
                ),
                piece: Piece(color: side, role: role),
                count: pockets.of(side, role),
                held:
                    pending != null &&
                    pending.board == which &&
                    pending.side == side &&
                    pending.role == role,
                enabled: droppable,
                // A reserve piece is dragged onto its square the way a piece
                // already on the board is; the click-then-click path stays for
                // anyone who prefers it, and for touch.
                drag: !setup && droppable && pockets.of(side, role) > 0
                    ? _PocketDrag(board: which, side: side, role: role)
                    : null,
                onDragStarted: () =>
                    controller.holdPocketPiece(which, side, role),
                onDragEnded: controller.releasePocketPiece,
                onTap: setup
                    ? () => controller.editPocket(which, side, role, 1)
                    : droppable
                    ? () => controller.selectPocketPiece(which, side, role)
                    : null,
                onSecondaryTap: setup
                    ? () => controller.editPocket(which, side, role, -1)
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}

/// One reserve slot. Empty slots stay in place at low opacity so the strip
/// never reflows as pieces arrive and leave.
class _PocketPiece extends StatelessWidget {
  const _PocketPiece({
    super.key,
    required this.piece,
    required this.count,
    required this.held,
    required this.enabled,
    required this.onTap,
    this.onSecondaryTap,
    this.drag,
    this.onDragStarted,
    this.onDragEnded,
  });

  final Piece piece;
  final int count;
  final bool held;
  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onSecondaryTap;

  /// What this slot carries when dragged, or null when it cannot be.
  final _PocketDrag? drag;
  final VoidCallback? onDragStarted;
  final VoidCallback? onDragEnded;

  static const double size = 36;

  @override
  Widget build(BuildContext context) {
    final body = _body(context);
    final payload = drag;
    if (payload == null) return body;
    return Draggable<_PocketDrag>(
      data: payload,
      // The pointer holds the piece by its middle, so the square under the
      // cursor is the square it lands on.
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Transform.translate(
        offset: const Offset(-size / 2, -size / 2),
        child: PieceImage(piece: piece, size: size),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: body),
      onDragStarted: onDragStarted,
      onDraggableCanceled: (_, _) => onDragEnded?.call(),
      onDragCompleted: onDragEnded,
      child: body,
    );
  }

  Widget _body(BuildContext context) {
    final empty = count == 0;
    final interactive = onTap != null && (!empty || onSecondaryTap != null);

    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: empty && onSecondaryTap == null ? null : onTap,
        onSecondaryTap: onSecondaryTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: size + 8,
          height: size + 6,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: held ? AppColors.surfaceHighlight : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: held ? Border.all(color: AppColors.ink) : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                // Empty slots stay legible enough to read as "none of these",
                // without competing with the pieces that are actually there.
                opacity: empty ? 0.16 : (enabled ? 1.0 : 0.45),
                child: PieceImage(piece: piece, size: size),
              ),
              // A count only when there is more than one: a lone piece is
              // already shown by being drawn, and a "1" on every slot is four
              // strips of noise.
              if (count > 1)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$count',
                      style: AppTextStyles.caption.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A reserve piece in flight between a pocket and a square.
class _PocketDrag {
  const _PocketDrag({
    required this.board,
    required this.side,
    required this.role,
  });

  final BughouseBoard board;
  final Side side;
  final Role role;
}

/// Everything that lands on the board's own rectangle but is not the board
/// widget's business: a dragged reserve piece, and a click in the editor.
///
/// The board widget draws itself and handles piece drags of its own; this
/// wraps it rather than reaching inside, so the geometry is repeated here —
/// eight squares across, origin at the top-left, flipped when the board is.
///
/// The editor's clicks come through here rather than through the board's
/// `onSquareClicked` because the board swallows every tap when user moves are
/// off, and turning them on in the editor would let a click-click pick a piece
/// up and play a real move in a pane whose job is to place pieces.
class _BoardSurface extends StatelessWidget {
  const _BoardSurface({
    required this.controller,
    required this.which,
    required this.flipped,
    required this.child,
  });

  final BughouseController controller;
  final BughouseBoard which;
  final bool flipped;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final target = DragTarget<_PocketDrag>(
      onWillAcceptWithDetails: (details) => details.data.board == which,
      onAcceptWithDetails: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final square = _squareAt(box.globalToLocal(details.offset), box.size);
        if (square == null) return;
        controller.dropPieceOn(
          which,
          details.data.side,
          details.data.role,
          square,
        );
      },
      builder: (context, _, _) => child,
    );

    if (controller.mode != BughouseMode.setup) return target;

    // In the editor the board is inert and this layer owns every click.
    //
    // Sitting a gesture detector *around* the board is not enough: the board
    // widget registers its own tap recognisers whether or not user moves are
    // enabled, wins the gesture arena as the inner competitor, and then throws
    // the tap away — which is why picking a piece and clicking a square did
    // nothing at all. Ignoring pointers on the board is what takes it out of
    // the arena. Nothing is lost by it: dragging a reserve piece and moving a
    // piece are both already off while editing.
    return Builder(
      builder: (inner) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => _edit(inner, details.localPosition, erase: false),
        onSecondaryTapUp: (details) =>
            _edit(inner, details.localPosition, erase: true),
        child: IgnorePointer(child: target),
      ),
    );
  }

  void _edit(BuildContext context, Offset local, {required bool erase}) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final square = _squareAt(local, box.size);
    if (square == null) return;
    controller.applyTool(which, square, erase: erase);
  }

  /// The square under [local], or null when the point landed off the board.
  Square? _squareAt(Offset local, Size size) {
    final cell = size.width / 8;
    if (cell <= 0) return null;
    final col = (local.dx / cell).floor();
    final row = (local.dy / cell).floor();
    if (col < 0 || col > 7 || row < 0 || row > 7) return null;
    final file = flipped ? 7 - col : col;
    final rank = flipped ? row : 7 - row;
    return parseSquare('${String.fromCharCode(97 + file)}${rank + 1}');
  }
}
