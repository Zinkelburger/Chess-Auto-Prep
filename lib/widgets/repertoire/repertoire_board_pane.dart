import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../theme/app_colors.dart';
import '../chess_board_widget.dart';

/// Chess board with optional preview overlay and generation lock UI.
class RepertoireBoardPane extends StatelessWidget {
  const RepertoireBoardPane({
    super.key,
    required this.boardPreview,
    required this.fen,
    required this.positionFromFen,
    required this.boardFlipped,
    required this.isGenerating,
    required this.isGenerationPaused,
    required this.onMove,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
  });

  final BoardPreviewController boardPreview;
  final String fen;
  final Position Function(String fen) positionFromFen;
  final bool boardFlipped;
  final bool isGenerating;
  final bool isGenerationPaused;
  final void Function(CompletedMove move) onMove;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ListenableBuilder(
          listenable: boardPreview,
          builder: (context, _) {
            final isPreview = boardPreview.isPreview &&
                boardPreview.target == BoardPreviewTarget.mainBoard;
            final displayFen =
                isPreview ? boardPreview.previewFen! : fen;
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
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('Preview',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 11)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        if (isGenerating)
          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: 0.6),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 24,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isGenerationPaused
                          ? AppColors.warning
                          : AppColors.warningSurface,
                      width: 1.5,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isGenerationPaused)
                        const SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        )
                      else
                        Icon(
                          Icons.pause_circle_filled,
                          size: 36,
                          color: AppColors.warning,
                        ),
                      const SizedBox(height: 14),
                      Text(
                        isGenerationPaused
                            ? 'Generation Paused'
                            : 'Generating Repertoire...',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isGenerationPaused
                            ? 'Resume to continue building, or switch tabs to inspect the current position.'
                            : 'All other features are locked.\nPlease leave this running.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey[400],
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        alignment: WrapAlignment.center,
                        children: [
                          if (!isGenerationPaused)
                            FilledButton.icon(
                              onPressed: onPause,
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.warningSurface,
                              ),
                              icon:
                                  const Icon(Icons.pause, color: Colors.white),
                              label: const Text(
                                'Pause',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (isGenerationPaused) ...[
                            FilledButton.icon(
                              onPressed: onResume,
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.successSurface,
                              ),
                              icon: const Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                              ),
                              label: const Text(
                                'Resume',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            FilledButton.icon(
                              onPressed: onCancel,
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.dangerSurface,
                              ),
                              icon: const Icon(Icons.stop, color: Colors.white),
                              label: const Text(
                                'Cancel',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
