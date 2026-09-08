/// Spare pieces for the board editor, laid out the way lichess lays them
/// out: one strip per colour with the pointer at one end, the six pieces in
/// the middle and the bin at the other. Above the board is the far side's
/// strip and below it the near side's, so the strips flip with the board.
///
/// A spare piece answers two gestures. Drag it and it lands on the square
/// it is dropped on, leaving the pointer in hand. Click it and it becomes
/// the brush: the cursor over the board turns into the piece, and every
/// press or stroke on the board paints it, until the pointer or another
/// tool is picked. Right-clicking the board with a brush swaps its colour.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../core/board_editor_controller.dart';
import '../../theme/app_colors.dart';
import '../common/piece_image.dart';

/// Both strips stacked, for editors that keep their palette beside the
/// boards rather than around one board (bughouse has two).
class PiecePalette extends StatelessWidget {
  const PiecePalette({
    super.key,
    required this.tool,
    required this.onSelect,
    this.sides = const [Side.white, Side.black],
  });

  final EditorTool tool;
  final ValueChanged<EditorTool> onSelect;
  final List<Side> sides;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, side) in sides.indexed) ...[
          if (i > 0) const SizedBox(height: 4),
          SparePieceRow(side: side, tool: tool, onSelect: onSelect),
        ],
      ],
    );
  }
}

/// One colour's strip: pointer, king to pawn, bin. Eight equal slots, so
/// on a board-wide strip each slot is a square wide.
class SparePieceRow extends StatelessWidget {
  const SparePieceRow({
    super.key,
    required this.side,
    required this.tool,
    required this.onSelect,
  });

  final Side side;
  final EditorTool tool;
  final ValueChanged<EditorTool> onSelect;

  static const List<Role> roles = [
    Role.king,
    Role.queen,
    Role.rook,
    Role.bishop,
    Role.knight,
    Role.pawn,
  ];

  /// Slot height for a strip [width] wide: eight square slots, but never
  /// so tall that a strip dominates a narrow panel.
  static double heightFor(double width) => (width / 8).clamp(30, 64);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = heightFor(constraints.maxWidth);
        final pieceSize = height * 0.86;
        return Container(
          height: height,
          decoration: BoxDecoration(
            color: AppColors.surfaceInset,
            borderRadius: BorderRadius.circular(6),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              Expanded(
                child: _SpareSlot(
                  tooltip: 'Move pieces',
                  selected: tool is PointerTool,
                  onTap: () => onSelect(const PointerTool()),
                  child: Icon(
                    Icons.pan_tool_alt_outlined,
                    size: height * 0.5,
                    color: AppColors.ink,
                  ),
                ),
              ),
              for (final role in roles)
                Expanded(
                  child: _SparePiece(
                    piece: Piece(color: side, role: role),
                    size: pieceSize,
                    tool: tool,
                    onSelect: onSelect,
                  ),
                ),
              Expanded(
                child: _SpareSlot(
                  tooltip: 'Erase pieces',
                  selected: tool is EraserTool,
                  danger: true,
                  onTap: () => onSelect(const EraserTool()),
                  child: Icon(
                    Icons.delete_outline,
                    size: height * 0.5,
                    color: AppColors.ink,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SparePiece extends StatelessWidget {
  const _SparePiece({
    required this.piece,
    required this.size,
    required this.tool,
    required this.onSelect,
  });

  final Piece piece;
  final double size;
  final EditorTool tool;
  final ValueChanged<EditorTool> onSelect;

  @override
  Widget build(BuildContext context) {
    final brush = PieceBrush(piece);
    final selected = tool == brush;
    final name =
        '${piece.color == Side.white ? 'White' : 'Black'} ${piece.role.name}';
    return _SpareSlot(
      tooltip: '$name: drag onto the board, or click to paint with it',
      selected: selected,
      // Click: take the piece in hand, or put it down again.
      onTap: () => onSelect(selected ? const PointerTool() : brush),
      child: Draggable<Piece>(
        data: piece,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        // A drag is a one-off placement; the board's DragTarget places the
        // piece, so the pointer is what is left in hand afterwards. A drag
        // that ends off the board is a click that wandered: lichess takes
        // it as picking the piece up, and so do we.
        onDragStarted: () => onSelect(const PointerTool()),
        onDraggableCanceled: (_, _) => onSelect(brush),
        feedback: Transform.translate(
          offset: Offset(-size / 2, -size / 2),
          child: PieceImage(piece: piece, size: size),
        ),
        child: PieceImage(piece: piece, size: size),
      ),
    );
  }
}

class _SpareSlot extends StatelessWidget {
  const _SpareSlot({
    required this.tooltip,
    required this.selected,
    required this.onTap,
    required this.child,
    this.danger = false,
  });

  final String tooltip;
  final bool selected;
  final bool danger;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final tint = danger ? AppColors.danger : primary;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: onTap,
        hoverColor: tint.withValues(alpha: 0.12),
        child: Container(
          decoration: BoxDecoration(
            color: selected ? tint.withValues(alpha: 0.3) : null,
            border: Border(
              bottom: BorderSide(
                color: selected ? tint : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}
