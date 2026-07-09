/// Piece palette for the board editor: pick a piece brush or the eraser.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../core/board_editor_controller.dart';
import '../common/piece_image.dart';

class PiecePalette extends StatelessWidget {
  final BoardEditorController controller;

  const PiecePalette({super.key, required this.controller});

  static const List<Role> _roles = [
    Role.king,
    Role.queen,
    Role.rook,
    Role.bishop,
    Role.knight,
    Role.pawn,
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // Lighter backdrop than the app background so the black pieces
        // stand out.
        return Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _paletteRow(context, Side.white),
              const SizedBox(height: 4),
              _paletteRow(context, Side.black),
            ],
          ),
        );
      },
    );
  }

  Widget _paletteRow(BuildContext context, Side side) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final role in _roles)
          _PaletteButton(
            selected: switch (controller.tool) {
              PieceBrush(:final piece) =>
                piece.role == role && piece.color == side,
              _ => false,
            },
            onTap: () {
              final piece = Piece(color: side, role: role);
              final alreadySelected = switch (controller.tool) {
                PieceBrush(piece: final p) => p == piece,
                _ => false,
              };
              controller.selectTool(
                  alreadySelected ? null : PieceBrush(piece));
            },
            child: PieceImage(
                piece: Piece(color: side, role: role), size: 30),
          ),
        // Eraser only on the white row's trailing edge would look lopsided;
        // show it on both rows' end for symmetry? One is enough — white row.
        if (side == Side.white)
          _PaletteButton(
            selected: controller.tool is EraserTool,
            onTap: () {
              controller.selectTool(controller.tool is EraserTool
                  ? null
                  : const EraserTool());
            },
            child: const Icon(Icons.delete_outline, size: 22),
          )
        else
          const SizedBox(width: 38),
      ],
    );
  }
}

class _PaletteButton extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  const _PaletteButton({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 38,
        height: 38,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.25)
              : null,
          border: selected
              ? Border.all(color: theme.colorScheme.primary, width: 2)
              : Border.all(color: Colors.transparent, width: 2),
        ),
        child: Center(child: child),
      ),
    );
  }
}
