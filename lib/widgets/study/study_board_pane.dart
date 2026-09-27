/// Board + SAN input for Study mode.
library;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:dartchess/dartchess.dart' show Position;
import '../../features/studies/widgets/study_selector.dart';
import 'package:flutter/services.dart';

import '../../features/studies/controllers/study_controller.dart';
import '../../models/board_annotation.dart';
import '../../utils/board_shape_comments.dart';
import '../chess_board_widget.dart';
import '../training/move_input_widget.dart';

class StudyBoardPane extends StatelessWidget {
  const StudyBoardPane({
    super.key,
    required this.study,
    required this.moveInputKey,
    required this.onShapeDrawn,
  });

  final StudyController study;
  final GlobalKey<MoveInputWidgetState> moveInputKey;
  final void Function(String orig, String? dest) onShapeDrawn;

  @override
  Widget build(BuildContext context) => StudySelector<_BoardView>(
    study: study,
    select: (owner) {
      final cursor = owner.cursor;
      return _BoardView(
        cursor.position,
        cursor.flipped,
        parseBoardShapes(cursor.comment),
      );
    },
    builder: (context, view) => Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: RepaintBoundary(
                  key: const ValueKey('study-board-paint'),
                  child: ChessBoardWidget(
                    position: view.position,
                    flipped: view.flipped,
                    onMove: (move) => study.playSan(move.san),
                    annotations: view.annotations,
                    onShapeDrawn: onShapeDrawn,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: MoveInputWidget(
              key: moveInputKey,
              position: view.position,
              onMove: (move) => study.playSan(move.san),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Compare only values the board paints; prose, glyphs and save state do not
/// rebuild it. Shape parsing is bounded to the current position's comment.
class _BoardView {
  const _BoardView(this.position, this.flipped, this.annotations);
  final Position position;
  final bool flipped;
  final List<BoardAnnotation> annotations;
  @override
  bool operator ==(Object other) =>
      other is _BoardView &&
      position.fen == other.position.fen &&
      flipped == other.flipped &&
      listEquals(annotations, other.annotations);
  @override
  int get hashCode =>
      Object.hash(position.fen, flipped, Object.hashAll(annotations));
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
