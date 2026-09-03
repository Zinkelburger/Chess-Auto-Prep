import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/chess_utils.dart' show parseSquare;
import '../../../widgets/chess_board_widget.dart';
import '../../../widgets/common/piece_image.dart';
import '../controllers/bughouse_controller.dart';
import '../models/bughouse_state.dart';

/// One of the two boards, with the reserve above and below it.
///
/// The reserves are the point of the layout: in bughouse they are filled by
/// the *other* board, so seeing both boards and all four reserves at once is
/// how you read whether a mate threat is actually available.
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
    final ourSide = state.sideOn(which);
    final flipped = controller.isFlipped(which);
    final topSide = flipped ? Side.white : Side.black;
    final bottomSide = flipped ? Side.black : Side.white;
    final lastPly = controller.history.currentPly;
    final recent = lastPly != null && lastPly.board == which
        ? _squaresOf(lastPly.move)
        : <String>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Header(controller: controller, which: which, ourSide: ourSide),
        const SizedBox(height: 4),
        _PocketRow(controller: controller, which: which, side: topSide),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 1,
          child: _DropTarget(
            controller: controller,
            which: which,
            flipped: flipped,
            child: ChessBoardWidget(
              position: position,
              flipped: flipped,
              enableUserMoves: controller.mode == BughouseMode.play,
              recentMoveSquares: recent,
              highlightedSquares: {
                ..._dropTargets(),
                ...controller.hoveredSquares(which),
              },
              onSquareClicked: (square) => _onSquareClicked(square),
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
        const SizedBox(height: 4),
        _PocketRow(controller: controller, which: which, side: bottomSide),
      ],
    );
  }

  void _onSquareClicked(String algebraic) {
    final square = parseSquare(algebraic);
    if (square == null) return;
    if (controller.mode == BughouseMode.setup) {
      controller.applyTool(which, square);
      return;
    }
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

class _Header extends StatelessWidget {
  const _Header({
    required this.controller,
    required this.which,
    required this.ourSide,
  });

  final BughouseController controller;
  final BughouseBoard which;
  final Side ourSide;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final turn = state.board(which).turn;
    final ourTurn = state.isOurTurn(which);

    return Row(
      children: [
        Text(which.label, style: AppTextStyles.subtitle),
        const SizedBox(width: 8),
        // Wrapped rather than laid in a row: on a narrow window the two tags
        // are what has to give, not the board's name or its flip button.
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Tag(
                label: which == BughouseBoard.a
                    ? 'we play ${ourSide.name}'
                    : 'partner plays ${ourSide.name}',
              ),
              _Tag(label: '${turn.name} to move', emphasis: ourTurn),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Flip ${which.label}',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          icon: const Icon(Icons.swap_vert),
          onPressed: () => controller.toggleFlip(which),
        ),
      ],
    );
  }
}

/// One side's reserve, in the lichess crazyhouse shape: a strip the width of
/// the board holding all five droppable roles, dimmed when empty, each with a
/// count. Always showing every slot is the point — an empty strip is what a
/// bughouse player scans to see what they *could* be sent.
///
/// Kings never appear: they cannot be captured, so they never reach a reserve.
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
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(4),
        ),
        // Packed tight and left-aligned, the way lichess draws a crazyhouse
        // pocket: the reserve is read as one clump, not as five columns
        // stretched across the board.
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            // Which of the four players this reserve belongs to. It lives here
            // rather than in the header because a seat *is* a colour on a
            // board, which is exactly what a pocket strip already is.
            Tooltip(
              message: state.seatDescription(which, side),
              child: SizedBox(
                width: 20,
                child: Text(
                  state.seatLetter(which, side),
                  style: AppTextStyles.mono.copyWith(
                    color: position.turn == side
                        ? AppColors.ink
                        : AppColors.onSurfaceDim,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            for (final role in _reserveRoles)
              SizedBox(
                width: 44,
                child: _PocketPiece(
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
                  // already on the board is; the click-then-click path stays
                  // for anyone who prefers it, and for touch.
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

  static const double size = 40;

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
    final scheme = Theme.of(context).colorScheme;
    final empty = count == 0;
    final interactive = onTap != null && (!empty || onSecondaryTap != null);

    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: empty && onSecondaryTap == null ? null : onTap,
        onSecondaryTap: onSecondaryTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: held ? scheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: held ? Border.all(color: scheme.primary, width: 2) : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                // Empty slots stay legible enough to read as "none of these",
                // without competing with the pieces that are actually there.
                opacity: empty ? 0.18 : (enabled ? 1.0 : 0.45),
                child: PieceImage(piece: piece, size: size),
              ),
              if (count > 0)
                Positioned(
                  right: 2,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$count',
                      style: AppTextStyles.caption.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimary,
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

/// Catches a dragged reserve piece and turns where it landed into a square.
///
/// The board widget draws itself and handles piece drags of its own; this
/// wraps it rather than reaching inside, so the geometry is repeated here —
/// eight squares across, origin at the top-left, flipped when the board is.
class _DropTarget extends StatelessWidget {
  const _DropTarget({
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
    return DragTarget<_PocketDrag>(
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
  }

  /// The square under [local], or null when the drop landed off the board.
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

class _Tag extends StatelessWidget {
  const _Tag({required this.label, this.emphasis = false});
  final String label;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: emphasis
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: AppTextStyles.caption.copyWith(
          color: emphasis ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
