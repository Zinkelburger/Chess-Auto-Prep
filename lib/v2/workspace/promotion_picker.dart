import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'piece_image.dart';

/// The four pieces a pawn can become, in the order the old app and Lichess
/// offer them.
const promotionRoles = [Role.queen, Role.knight, Role.rook, Role.bishop];

/// Lichess's promotion choice: the board dimmed, the four pieces in a column
/// on the promotion file running from the last rank back towards the middle.
/// Anywhere else cancels, and a cancelled promotion plays no move.
class PromotionPicker extends StatelessWidget {
  const PromotionPicker({
    super.key,
    required this.color,
    required this.file,
    required this.fromTop,
    required this.square,
    required this.onChosen,
    required this.onCancel,
  });

  /// The side promoting, so the choices are that side's pieces.
  final Side color;

  /// Screen column of the promotion square, 0 at the left edge.
  final int file;

  /// Whether the column runs down from the top edge, which it does when the
  /// promoting side is the one shown at the bottom of the board.
  final bool fromTop;

  /// The side of one board square in pixels.
  final double square;

  final void Function(Role role) onChosen;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = BoardTheme.of(context);
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onCancel,
        child: ColoredBox(
          color: colors.scrim,
          child: Stack(
            children: [
              for (final (index, role) in promotionRoles.indexed)
                Positioned(
                  left: file * square,
                  top: (fromTop ? index : 7 - index) * square,
                  width: square,
                  height: square,
                  child: _Choice(
                    piece: Piece(color: color, role: role),
                    onTap: () => onChosen(role),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.piece, required this.onTap});

  final Piece piece;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: ValueKey('promote-${piece.role.letter}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: BoardTheme.of(context).promotionChoice,
            shape: BoxShape.circle,
          ),
          child: PieceImage(piece: piece),
        ),
      ),
    );
  }
}
