import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Full-surface scrim shown over the repertoire tab while a build actively
/// runs.
///
/// Blocks every interaction underneath (board, PGN editor, engine panes) and
/// hosts the pause control plus live progress. Pausing removes the overlay
/// entirely (see [GenerationPausedBanner]), frees the engine, and unlocks the
/// tab — from there the build can be resumed or discarded.
class GenerationLockOverlay extends StatelessWidget {
  const GenerationLockOverlay({
    super.key,
    required this.statusText,
    required this.canPause,
    required this.isCancelling,
    required this.onPause,
  });

  final String statusText;

  /// Pause is offered only in phases whose loops honor the pause gate.
  final bool canPause;

  /// True while a discard/cancel triggered elsewhere (e.g. the Jobs panel)
  /// unwinds; the overlay reflects it and disables Pause.
  final bool isCancelling;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.scrimHeavy,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          constraints: const BoxConstraints(maxWidth: 420),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.warningSurface, width: 1.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 14),
              Text(
                isCancelling ? 'Cancelling...' : 'Generating Repertoire...',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'This tab is locked while your repertoire builds.\n'
                'Training, Study, and puzzles stay available.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.onSurfaceSoft,
                  height: 1.5,
                ),
              ),
              if (statusText.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  statusText,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.onSurfaceMuted,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Tooltip(
                message: canPause
                    ? 'Pause the build and free the engine'
                    : 'This phase finishes on its own and cannot pause',
                child: FilledButton.icon(
                  onPressed: canPause && !isCancelling ? onPause : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.warningSurface,
                  ),
                  icon: const Icon(Icons.pause, color: AppColors.onWarning),
                  label: const Text(
                    'Pause',
                    style: TextStyle(
                      color: AppColors.onWarning,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Pausing frees the engine and unlocks the tab.\n'
                'You can resume it later — or discard it if you change '
                'your mind.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.onSurfaceMuted,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slim, non-blocking banner shown instead of the overlay while a build is
/// paused: the tab and engine are fully usable, and the build can be resumed
/// or discarded from here.
class GenerationPausedBanner extends StatelessWidget {
  const GenerationPausedBanner({
    super.key,
    required this.onResume,
    required this.onDiscard,
  });

  final VoidCallback onResume;

  /// Throw the build away for good (after confirmation at the call site).
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.warningSurface.withValues(alpha: 0.25),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: AppColors.warning, width: 1),
          ),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.pause_circle_filled,
              size: 18,
              color: AppColors.warning,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: const Text(
                'Build paused — board and engine are free. '
                'Resume it when you like, or discard it if you don\'t want it.',
                style: TextStyle(fontSize: 12.5, color: AppColors.inkSoft),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: onResume,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.successSurface,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              icon: const Icon(
                Icons.play_arrow,
                size: 16,
                color: AppColors.ink,
              ),
              label: const Text(
                'Resume',
                style: TextStyle(color: AppColors.ink, fontSize: 12.5),
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: onDiscard,
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                foregroundColor: AppColors.danger,
                side: const BorderSide(color: AppColors.danger),
              ),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Discard', style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
      ),
    );
  }
}
