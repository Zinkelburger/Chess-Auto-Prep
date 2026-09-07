import 'package:flutter/material.dart';
import '../../core/board_editor_controller.dart';
import 'editable_board.dart';

/// Shared editor with free piece movement and palette drag placement.
class BoardEditorWidget extends StatelessWidget {
  const BoardEditorWidget({super.key, required this.controller});
  final BoardEditorController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) => EditableBoard(
      pieceAt: controller.pieceAt,
      onTap: controller.tapSquare,
      onRemove: controller.removePiece,
      onMove: controller.movePiece,
      onPlace: controller.setPiece,
    ),
  );
}
