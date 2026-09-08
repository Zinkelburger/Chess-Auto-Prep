import 'package:flutter/material.dart';
import '../../core/board_editor_controller.dart';
import 'editable_board.dart';

/// Shared editor board bound to a [BoardEditorController]: press or stroke
/// with the tool in hand, drag pieces with the pointer, drop palette pieces.
class BoardEditorWidget extends StatelessWidget {
  const BoardEditorWidget({super.key, required this.controller});
  final BoardEditorController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) => EditableBoard(
      pieceAt: controller.pieceAt,
      tool: controller.tool,
      flipped: controller.flipped,
      onPress: controller.pressSquare,
      onPaint: controller.paintSquare,
      onSecondaryPress: controller.secondaryPressSquare,
      onRemove: controller.removePiece,
      onMove: controller.movePiece,
      onPlace: controller.setPiece,
    ),
  );
}
