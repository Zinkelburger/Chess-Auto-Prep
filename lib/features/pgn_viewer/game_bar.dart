import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../../workspace/document_session.dart';
import '../../workspace/game_review.dart';
import '../../workspace/solitaire.dart';
import '../../ui/app_keys.dart';

/// The three things done to a game in the viewer, as buttons under its
/// heading: edit it, have the engine analyze it, or play it as solitaire.
/// The Actions menu has the same three; these are where the eye already is.
class ViewerGameBar extends StatelessWidget {
  const ViewerGameBar({
    super.key,
    required this.session,
    required this.editing,
    required this.review,
    required this.solitaire,
    required this.onAnalyze,
    required this.onSolitaire,
  });

  final DocumentSession session;
  final ValueNotifier<bool> editing;
  final GameReview? review;
  final Solitaire solitaire;

  /// Shows the Game review tab and starts the review, or stops one running.
  final VoidCallback onAnalyze;

  /// Shows the Solitaire tab with its setup, or stops a session.
  final VoidCallback onSolitaire;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      session,
      editing,
      solitaire,
      if (review != null) review!,
    ]),
    builder: (context, _) {
      final open = session.chapter != null && !session.isScratch;
      if (!open) return const SizedBox.shrink();
      final review = this.review;
      final running = review?.running ?? false;
      final playing = solitaire.active && !solitaire.finished;
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          readingCardInset,
          0,
          readingCardInset,
          Space.s,
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: Space.s,
          runSpacing: Space.s,
          children: [
            _Button(
              key: const ValueKey('viewer-edit'),
              icon: editing.value ? Icons.check : Icons.edit_outlined,
              label: editing.value ? 'Done editing' : 'Edit',
              tooltip: AppKey.edit.tip(
                editing.value
                    ? 'Close the edit strip'
                    : 'Add comments, glyphs and moves',
              ),
              onPressed: playing ? null : () => editing.value = !editing.value,
            ),
            if (review != null)
              _Button(
                key: const ValueKey('viewer-analyze'),
                icon: running ? Icons.stop : Icons.query_stats,
                label: running
                    ? 'Stop analysis · ${review.completed}/${review.total}'
                    : 'Analyze game',
                tooltip: running
                    ? 'Stop the engine review'
                    : 'Stockfish checks every move, marks mistakes and '
                          'draws the evaluation graph',
                onPressed: playing ? null : onAnalyze,
              ),
            _Button(
              key: const ValueKey('viewer-solitaire'),
              icon: solitaire.active
                  ? Icons.close
                  : Icons.psychology_alt_outlined,
              label: playing
                  ? 'Stop solitaire'
                  : solitaire.active
                  ? 'Close solitaire'
                  : 'Solitaire',
              tooltip: playing
                  ? AppKey.leave.tip('Show the whole game again')
                  : 'Guess the game’s moves one at a time',
              onPressed: running ? null : onSolitaire,
            ),
          ],
        ),
      );
    },
  );
}

class _Button extends StatelessWidget {
  const _Button({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: OutlinedButton.icon(
      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    ),
  );
}
