import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../../models/board_annotation.dart';
import '../../../models/completed_move.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/chess_utils.dart' show uciHighlightSquares;
import '../../../widgets/chess_board_widget.dart' show ChessBoardWidget;

/// Chess board with optional preview overlay.
///
/// Generation locking is handled above this widget: the repertoire screen
/// covers the whole tab with a [GenerationLockOverlay] while a build runs.
class RepertoireBoardPane extends StatelessWidget {
  const RepertoireBoardPane({
    super.key,
    required this.boardPreview,
    required this.fen,
    required this.positionFromFen,
    required this.boardFlipped,
    required this.onMove,
    this.annotations = const [],
    this.recentMoveSquares = const {},
  });

  final BoardPreviewController boardPreview;
  final String fen;
  final Position Function(String fen) positionFromFen;
  final bool boardFlipped;
  final void Function(CompletedMove move) onMove;
  final List<BoardAnnotation> annotations;

  /// From/to squares of the move that reached [fen], kept tinted so the board
  /// says where you are the way every other board in the app does.
  final Set<String> recentMoveSquares;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: boardPreview,
      builder: (context, _) {
        final isPreview =
            boardPreview.isPreview &&
            boardPreview.target == BoardPreviewTarget.mainBoard;
        final displayFen = isPreview ? boardPreview.previewFen! : fen;
        final position = positionFromFen(displayFen);
        // A preview shows a different position, so neither the audit
        // annotations nor the hovered move from this position apply there.
        final shownAnnotations = isPreview
            ? const <BoardAnnotation>[]
            : annotations;
        final hoverSquares = isPreview
            ? const <String>{}
            : boardPreview.hoverSquares;

        return Container(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: Stack(
                children: [
                  Opacity(
                    opacity: isPreview ? 0.85 : 1.0,
                    // No per-FEN key: the board widget resets its own drag
                    // state when the position changes, and remounting it on
                    // every move rebuilt every piece image and painter.
                    child: ChessBoardWidget(
                      position: position,
                      flipped: boardFlipped,
                      annotations: shownAnnotations,
                      highlightedSquares: hoverSquares,
                      // In a preview the cursor's trail belongs to another
                      // position; mark the move that reached the previewed
                      // one instead, when its source told us which it was.
                      recentMoveSquares: isPreview
                          ? uciHighlightSquares(boardPreview.lastMoveUci ?? '')
                          : recentMoveSquares,
                      onPieceSelected: (square) {},
                      onMove: isPreview
                          ? null
                          : (CompletedMove move) => onMove(move),
                    ),
                  ),
                  if (isPreview)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.scrimHeavy,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'Preview',
                          style: TextStyle(
                            color: AppColors.overlayInk,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
