import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../chess_board_widget.dart'
    show BoardAnnotation, ChessBoardWidget, CompletedMove;

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
  });

  final BoardPreviewController boardPreview;
  final String fen;
  final Position Function(String fen) positionFromFen;
  final bool boardFlipped;
  final void Function(CompletedMove move) onMove;
  final List<BoardAnnotation> annotations;

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

        return Container(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: Stack(
                children: [
                  Opacity(
                    opacity: isPreview ? 0.85 : 1.0,
                    child: ChessBoardWidget(
                      key: ValueKey(displayFen),
                      position: position,
                      flipped: boardFlipped,
                      annotations: isPreview ? const [] : annotations,
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
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'Preview',
                          style: TextStyle(color: Colors.white70, fontSize: 11),
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
