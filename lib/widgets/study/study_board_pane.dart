/// Board + SAN input for Study mode.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/study_controller.dart';
import '../../models/board_annotation.dart';
import '../../utils/board_shape_comments.dart';
import '../../utils/keyboard_shortcut_utils.dart';
import '../chess_board_widget.dart';
import '../training/move_input_widget.dart';

class StudyBoardPane extends StatelessWidget {
  const StudyBoardPane({
    super.key,
    required this.study,
    required this.moveInputKey,
    required this.keyBindings,
    required this.onShapeDrawn,
  });

  final StudyController study;
  final GlobalKey<MoveInputWidgetState> moveInputKey;
  final List<KeyBinding> keyBindings;
  final void Function(String orig, String? dest) onShapeDrawn;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: ChessBoardWidget(
                  position: study.currentPosition,
                  flipped: study.flipped,
                  onMove: (move) => study.playSan(move.san),
                  annotations: parseBoardShapes(study.cursorComment),
                  onShapeDrawn: onShapeDrawn,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: MoveInputWidget(
              key: moveInputKey,
              position: study.currentPosition,
              onMove: (move) => study.playSan(move.san),
              onNavigationKey: (event) =>
                  handleMoveInputNavigationKey(keyBindings, event),
            ),
          ),
        ],
      ),
    );
  }
}

/// Right-drag on the board: draw an arrow (or a circle) into the current
/// move's comment. Modifiers pick the colour the way Lichess does.
void applyStudyBoardShape(
  StudyController study,
  String orig,
  String? dest, {
  required AnnotationBrush brush,
}) {
  final comment = study.cursorComment;
  final next = toggleBoardShape(
    parseBoardShapes(comment),
    BoardAnnotation(orig: orig, dest: dest, brush: brush),
  );
  study.setComment(study.path, writeBoardShapes(comment, next));
}

AnnotationBrush studyShapeBrushFromKeyboard() {
  final keys = HardwareKeyboard.instance;
  if (keys.isShiftPressed) return AnnotationBrush.red;
  if (keys.isAltPressed) return AnnotationBrush.blue;
  if (keys.isControlPressed) return AnnotationBrush.yellow;
  return AnnotationBrush.green;
}
