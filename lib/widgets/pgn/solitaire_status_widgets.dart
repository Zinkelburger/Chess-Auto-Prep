/// Solitaire-mode strips shown above the movetext in the PGN viewer's game
/// tab: the in-progress status bar (progress, first-try tally, reveal-delay
/// settings) and the end-of-game completion banner.
library;

import 'package:flutter/material.dart';

import '../../core/pgn_viewer_controller.dart';
import '../../theme/app_colors.dart';

/// Compact end-of-game strip shown above the movetext instead of a modal
/// overlay: the user is left freely browsing their fully annotated game.
class SolitaireCompleteBanner extends StatelessWidget {
  final PgnViewerController controller;

  /// Copies the current game's annotated PGN (with guess notes) to the clipboard.
  final VoidCallback onCopyPgn;

  /// Opens the "Add game to study" picker for the annotated game.
  final VoidCallback onAddToStudy;

  const SolitaireCompleteBanner({
    super.key,
    required this.controller,
    required this.onCopyPgn,
    required this.onAddToStudy,
  });

  @override
  Widget build(BuildContext context) {
    final s = controller.solitaire;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: AppColors.success.withValues(alpha: 0.12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.flag, size: 16, color: AppColors.success),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Complete — ${s.correctFirstTry}/${s.totalUserMoves} '
                  'first-try'
                  '${s.revealedCount > 0 ? ', ${s.revealedCount} revealed' : ''}'
                  '.',
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Actions wrap when the panel is narrow so nothing clips.
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: onCopyPgn,
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text('Copy PGN'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: onAddToStudy,
                icon: const Icon(Icons.menu_book_outlined, size: 16),
                label: const Text('Add to study…'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              FilledButton.tonal(
                onPressed: controller.nextGame,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: const TextStyle(fontSize: 12),
                ),
                child: const Text('Next game (N)'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Solitaire progress strip: user color, revealed/total progress bar,
/// first-try tally, and the settings menu.
class SolitaireStatusBar extends StatelessWidget {
  final PgnViewerController controller;

  /// Hands keyboard focus back to the screen after the settings menu closes.
  final VoidCallback onReclaimFocus;

  const SolitaireStatusBar({
    super.key,
    required this.controller,
    required this.onReclaimFocus,
  });

  @override
  Widget build(BuildContext context) {
    final s = controller.solitaire;
    final progress = s.totalMoves > 0 ? s.revealedPly / s.totalMoves : 0.0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(
        context,
      ).colorScheme.primaryContainer.withValues(alpha: 0.3),
      child: Row(
        children: [
          Icon(
            Icons.psychology,
            size: 16,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            'Solitaire (${s.userIsWhite ? "White" : "Black"})',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: progress, minHeight: 6),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${s.revealedPly}/${s.totalMoves}',
            style: const TextStyle(fontSize: 12),
          ),
          if (s.totalUserMoves > 0) ...[
            const SizedBox(width: 8),
            Text(
              '${s.correctFirstTry}/${s.totalUserMoves} first-try',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceSoft,
              ),
            ),
          ],
          const SizedBox(width: 4),
          _SolitaireSettingsButton(
            controller: controller,
            onReclaimFocus: onReclaimFocus,
          ),
        ],
      ),
    );
  }
}

class _SolitaireSettingsButton extends StatelessWidget {
  final PgnViewerController controller;
  final VoidCallback onReclaimFocus;

  const _SolitaireSettingsButton({
    required this.controller,
    required this.onReclaimFocus,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: Icon(
        Icons.more_vert,
        size: 16,
        color: Theme.of(context).colorScheme.primary,
      ),
      tooltip: 'Solitaire settings',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      style: IconButton.styleFrom(
        minimumSize: const Size(28, 28),
        padding: const EdgeInsets.all(4),
      ),
      itemBuilder: (_) {
        final currentDelay = controller.solitaire.revealDelaySec;
        return [
          const PopupMenuItem(
            enabled: false,
            height: 32,
            child: Text(
              'Reveal delay',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          for (final sec in [0, 15, 30, 60, 90, 120])
            PopupMenuItem(
              value: 'delay_$sec',
              height: 36,
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: sec == currentDelay
                        ? Icon(
                            Icons.check,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    sec == 0 ? 'No delay' : '${sec}s',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
        ];
      },
      onSelected: (value) {
        if (value.startsWith('delay_')) {
          final sec = int.parse(value.substring(6));
          controller.setSolitaireRevealDelay(sec);
        }
        onReclaimFocus();
      },
    );
  }
}
