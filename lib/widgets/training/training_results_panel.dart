import '../../features/training/controllers/training_session_controller.dart';
import '../../utils/app_shortcuts.dart';
import '../shortcut_tooltip.dart';
import 'package:flutter/material.dart';

import '../../models/repertoire_review_entry.dart';
import '../../features/training/models/training_settings.dart';
import '../../features/training/models/training_phase.dart';
import '../../theme/app_colors.dart';
import '../../utils/time_format.dart';
import 'training_progress_panel.dart';

/// Presentation of the session-owned completion, rating and next commands.
/// Mounting or rebuilding this panel never starts persistence or advancement.
class TrainingResultsPanel extends StatelessWidget {
  const TrainingResultsPanel({super.key, required this.session});
  final TrainingSessionController session;

  bool get _isLinear => session.repetitionMode == RepetitionMode.linear;

  Widget _ratingButtons() => LayoutBuilder(
    builder: (context, constraints) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (rating, label, color) in [
          (ReviewRating.again, 'Again', AppColors.srsAgain),
          (ReviewRating.hard, 'Hard', AppColors.srsHard),
          (ReviewRating.good, 'Good', AppColors.srsGood),
          (ReviewRating.easy, 'Easy', AppColors.srsEasy),
        ])
          SizedBox(
            width: (constraints.maxWidth - 8) / 2,
            child: ShortcutTooltip(
              description: label,
              shortcut: switch (rating) {
                ReviewRating.again => AppShortcut.rateAgain,
                ReviewRating.hard => AppShortcut.rateHard,
                ReviewRating.good => AppShortcut.rateGood,
                ReviewRating.easy => AppShortcut.rateEasy,
              },
              child: _RatingButton(
                label: label,
                color: color,
                interval: session.previewRatingInterval(rating),
                onRate: () => session.rateLine(rating),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _buildLinearResult(ThemeData theme) {
    final isTactics = session.trainingMode == TrainingMode.tactics;
    final clean = !session.lineHadMistake;
    final message = isTactics
        ? (clean ? 'Puzzle solved!' : 'Solved — with mistakes.')
        : (clean ? 'Line complete!' : 'Line complete — with mistakes.');
    final remaining = session.dueQueue.length;

    if (session.settings.autoNext) {
      return Center(child: Text(message, style: theme.textTheme.bodyMedium));
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                clean ? Icons.check_circle_outline : Icons.error_outline,
                size: 20,
                color: AppColors.onSurfaceSoft,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(message, style: theme.textTheme.titleSmall)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$remaining ${isTactics ? 'puzzle' : 'line'}'
            '${remaining == 1 ? '' : 's'} left in this set.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: session.canAdvance ? session.nextLine : null,
              icon: const Icon(Icons.skip_next),
              label: Text(isTactics ? 'Next puzzle' : 'Next line'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The screen renders the existing failure/Retry surface for this owner.
    if (session.phase != TrainingPhase.finished || session.error != null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);

    if (session.completionBusy) {
      return const Center(child: Text('Saving result…'));
    }
    if (_isLinear) return _buildLinearResult(theme);

    final entry = session.reviewMap[session.currentLine?.id];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            session.completionCommitted
                ? 'Line complete!'
                : 'How well did you know this?',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          if (session.canRate) _ratingButtons(),
          const SizedBox(height: 16),
          if (entry != null && entry.lastReviewedUtc != null) ...[
            Text(
              'Last reviewed: ${formatTimeAgo(entry.lastReviewedUtc!)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
          ],
          if (entry != null)
            Text(
              'Pass: ${entry.passCount} / Fail: ${entry.failCount}',
              style: theme.textTheme.bodySmall,
            ),
          if (!session.settings.autoNext) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: session.canAdvance ? session.nextLine : null,
                icon: const Icon(Icons.skip_next),
                label: const Text('Next Line'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// End of a Learn or Review run: what was done, and the two things worth
/// doing next. Replaces re-asking for a rating on the last line.
class TrainingRunCompletePanel extends StatelessWidget {
  final String title;
  final int sessionCorrect;
  final int sessionIncorrect;
  final int sessionStreak;

  /// Lines still untrained / due in the current scope, for the follow-on
  /// buttons.
  final int untrainedCount;
  final int dueCount;
  final VoidCallback onBackToList;
  final VoidCallback onLearn;
  final VoidCallback onReview;

  /// How many lines the next Learn / Review run will actually cover, or 0
  /// when that run is uncapped. The follow-on buttons promise the batch and
  /// mention the backlog, rather than promising the whole backlog.
  final int learnBatchSize;
  final int reviewBatchSize;

  const TrainingRunCompletePanel({
    super.key,
    required this.title,
    required this.sessionCorrect,
    required this.sessionIncorrect,
    required this.sessionStreak,
    required this.untrainedCount,
    required this.dueCount,
    required this.onBackToList,
    required this.onLearn,
    required this.onReview,
    this.learnBatchSize = 0,
    this.reviewBatchSize = 0,
  });

  /// "Learn 10 more · 920 left" when capped, "Learn 12 untrained" when not.
  static String _batchLabel(String verb, int batch, int pool, String noun) {
    if (batch <= 0 || batch >= pool) return '$verb $pool $noun';
    return '$verb $batch more · $pool left';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          const Icon(
            Icons.check_circle_outline,
            size: 48,
            color: AppColors.onSurfaceSoft,
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          if (sessionCorrect + sessionIncorrect > 0) ...[
            const SizedBox(height: 16),
            SessionStatsBar(
              sessionCorrect: sessionCorrect,
              sessionIncorrect: sessionIncorrect,
              sessionStreak: sessionStreak,
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onBackToList,
            icon: const Icon(Icons.list_alt, size: 18),
            label: const Text('Back to the line list'),
          ),
          if (dueCount > 0) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onReview,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(
                _batchLabel('Review', reviewBatchSize, dueCount, 'due'),
              ),
            ),
          ],
          if (untrainedCount > 0) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onLearn,
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(
                _batchLabel(
                  'Learn',
                  learnBatchSize,
                  untrainedCount,
                  'untrained',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RatingButton extends StatelessWidget {
  final String label;
  final Color color;
  final double interval;
  final VoidCallback onRate;

  const _RatingButton({
    required this.label,
    required this.color,
    required this.interval,
    required this.onRate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final intervalLabel = formatReviewInterval(interval);

    return Material(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onRate,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                intervalLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
