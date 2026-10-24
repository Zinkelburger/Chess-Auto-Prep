import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../chess/bughouse/table.dart';
import '../../ui/theme.dart';

/// A player's hand as lila's crazyhouse pocket: five slots, each [square]
/// wide, in a grey well. Pieces held show in full with their count; empty
/// slots stay in place, faint. While [live] — its player on move — a piece
/// held can be clicked ([onPick]) or dragged onto the board.
///
/// With [onStep], a − and a + appear in a slot's upper corners while the
/// pointer is over it or one of them has the keyboard's focus; they take
/// one of that piece away or add one, within 0…[handLimit].
class PocketWell extends StatefulWidget {
  const PocketWell({
    super.key,
    required this.pockets,
    required this.side,
    required this.owner,
    required this.square,
    this.seat,
    this.live = false,
    this.picked,
    this.onPick,
    this.onStep,
  });

  final Pockets pockets;
  final Side side;

  /// Whose hand: `White`, or `Player A` with both boards shown.
  final String owner;
  final double square;

  /// The seat, which keys each slot; null on a preview.
  final Seat? seat;
  final bool live;
  final Role? picked;
  final ValueChanged<Role>? onPick;
  final void Function(Role role, int by)? onStep;

  @override
  State<PocketWell> createState() => _PocketWellState();
}

class _PocketWellState extends State<PocketWell> {
  /// The slot under the pointer, and the one whose − or + has the focus.
  Role? _hovered;
  Role? _focused;

  void _hover(Role role, bool on) {
    if (!mounted) return;
    final hovered = on ? role : (_hovered == role ? null : _hovered);
    if (hovered != _hovered) setState(() => _hovered = hovered);
  }

  void _focus(Role role, bool on) {
    if (!mounted) return;
    final focused = on ? role : (_focused == role ? null : _focused);
    if (focused != _focused) setState(() => _focused = focused);
  }

  Widget _withSteps(Role role, Widget slot) {
    final onStep = widget.onStep;
    if (onStep == null) return slot;
    final count = widget.pockets.of(widget.side, role);
    final shown = _hovered == role || _focused == role;
    Widget step(int by) => _HandStep(
      side: widget.side,
      role: role,
      by: by,
      slot: widget.square,
      shown: shown,
      onPressed: () => onStep(role, by),
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (on) => _focus(role, on),
      child: MouseRegion(
        onEnter: (_) => _hover(role, true),
        onExit: (_) => _hover(role, false),
        child: Stack(
          children: [
            slot,
            if (count > 0) Positioned(left: 0, top: 0, child: step(-1)),
            if (count < handLimit) Positioned(right: 0, top: 0, child: step(1)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pockets = widget.pockets;
    final side = widget.side;
    final square = widget.square;
    return Container(
      width: square * reserveRoles.length,
      height: square,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: labPocketWell,
        borderRadius: BorderRadius.circular(Space.xs),
      ),
      child: Row(
        children: [
          for (final role in reserveRoles)
            _withSteps(
              role,
              _ReservePiece(
                key: switch (widget.seat) {
                  final seat? => ValueKey(('reserve', seat, role)),
                  null => null,
                },
                piece: Piece(color: side, role: role),
                count: pockets.of(side, role),
                owner: widget.owner,
                size: square,
                live: widget.live && pockets.of(side, role) > 0,
                picked: widget.live && widget.picked == role,
                onPick: () => widget.onPick?.call(role),
              ),
            ),
        ],
      ),
    );
  }
}

/// One − or + in a pocket slot's corner, shown only while its slot is
/// pointed at or focused; hidden, it still takes the keyboard's focus,
/// which shows it.
class _HandStep extends StatelessWidget {
  const _HandStep({
    required this.side,
    required this.role,
    required this.by,
    required this.slot,
    required this.shown,
    required this.onPressed,
  });

  final Side side;
  final Role role;
  final int by;

  /// The slot's width, which sizes the chip.
  final double slot;
  final bool shown;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colour = side == Side.white ? 'White' : 'Black';
    final size = (slot * 0.4).clamp(labHandStepMin, labHandStepMax);
    return IgnorePointer(
      ignoring: !shown,
      child: Opacity(
        opacity: shown ? 1 : 0,
        child: IconButton(
          tooltip: by > 0
              ? 'One more ${role.name} for $colour'
              : 'One ${role.name} fewer for $colour',
          onPressed: onPressed,
          icon: Icon(by > 0 ? Icons.add : Icons.remove),
          iconSize: size * 0.75,
          color: labHandStepInk,
          style: IconButton.styleFrom(
            backgroundColor: labHandStep,
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            fixedSize: Size(size, size),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Space.xs),
            ),
          ),
        ),
      ),
    );
  }
}

/// The dot beside the hand of the player on move; its place is kept when
/// the other player is.
class TurnDot extends StatelessWidget {
  const TurnDot({super.key, required this.side, required this.shown});

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

/// The small board that floats under a hovered engine move: one board of
/// the table after the move, the move highlighted, with both hands.
class BughousePreviewBoard extends StatelessWidget {
  const BughousePreviewBoard({
    super.key,
    required this.position,
    required this.orientation,
    required this.lastMove,
  });

  final Crazyhouse position;
  final Side orientation;

  /// As UCI.
  final String lastMove;

  /// How much room the board and its hands take.
  static const size = Size(
    previewBoardSize,
    previewBoardSize + 2 * (previewBoardSize / 8 + 2 * Space.xs),
  );

  @override
  Widget build(BuildContext context) {
    const square = previewBoardSize / 8;
    Widget hand(Side side) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.xs,
        vertical: Space.xs,
      ),
      child: Row(
        children: [
          TurnDot(side: side, shown: position.turn == side),
          const SizedBox(width: Space.xs),
          PocketWell(
            pockets: position.pockets!,
            side: side,
            owner: side == Side.white ? 'White' : 'Black',
            square: square,
          ),
        ],
      ),
    );
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          hand(orientation.opposite),
          StaticChessboard(
            size: previewBoardSize,
            orientation: orientation,
            fen: position.fen,
            lastMove: Move.parse(lastMove),
            settings: BoardTheme.of(context).previewSettings,
          ),
          hand(orientation),
        ],
      ),
    );
  }
}

class _ReservePiece extends StatefulWidget {
  const _ReservePiece({
    super.key,
    required this.piece,
    required this.count,
    required this.owner,
    required this.size,
    required this.live,
    required this.picked,
    required this.onPick,
  });

  final Piece piece;
  final int count;

  /// Whose hand: `White`, or `Player A` with both boards shown.
  final String owner;
  final double size;

  /// Whether its player is on move, so it may be dropped now.
  final bool live;
  final bool picked;
  final VoidCallback onPick;

  @override
  State<_ReservePiece> createState() => _ReservePieceState();
}

class _ReservePieceState extends State<_ReservePiece> {
  bool _hovered = false;

  void _hover(bool on) {
    if (mounted && _hovered != on) setState(() => _hovered = on);
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final count = widget.count;
    final role = widget.piece.role.name;
    Widget image() => PieceWidget(
      piece: widget.piece,
      size: size,
      pieceAssets: PieceSet.cburnettAssets,
    );
    final face = Container(
      width: size,
      height: size,
      color: widget.picked
          ? BoardTheme.of(context).selected
          : widget.live && _hovered
          ? labPocketHover
          : null,
      child: Stack(
        children: [
          Opacity(
            opacity: count == 0 ? labPocketEmptyOpacity : 1,
            child: image(),
          ),
          if (count > 0)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.xs,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: labPocketCount,
                  borderRadius: BorderRadius.circular(Space.xs),
                ),
                child: Text('$count', style: labPocketCountStyle(size)),
              ),
            ),
        ],
      ),
    );
    final label = '${widget.owner}: $count $role in hand';
    if (!widget.live) {
      return Tooltip(
        message: count == 0 ? 'No $role in hand' : '$label · waiting for turn',
        child: Semantics(label: label, child: face),
      );
    }
    return Tooltip(
      message:
          '$label · click, then click a highlighted square, or drag onto the board',
      child: Semantics(
        label: label,
        selected: widget.picked,
        button: true,
        child: Draggable<Piece>(
          data: widget.piece,
          // Held under the pointer by its middle, as a piece on the board is.
          dragAnchorStrategy: (draggable, context, position) =>
              Offset(size / 2, size / 2),
          feedback: image(),
          childWhenDragging: Opacity(opacity: 0.3, child: face),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => _hover(true),
            onExit: (_) => _hover(false),
            child: GestureDetector(onTap: widget.onPick, child: face),
          ),
        ),
      ),
    );
  }
}
