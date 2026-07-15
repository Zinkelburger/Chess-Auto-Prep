import 'package:flutter/material.dart';

import '../../models/repertoire_line.dart';
import '../../models/repertoire_review_entry.dart';
import '../../models/training_settings.dart';
import '../../services/repertoire_review_service.dart';
import '../../services/training/training_phase.dart';
import 'training_progress_panel.dart';

/// Line completion UI: self-rating, all-caught-up, and auto-rate placeholder.
class TrainingResultsPanel extends StatefulWidget {
  final TrainingPhase phase;
  final RepertoireLine? currentLine;
  final List<RepertoireLine> dueQueue;
  final Map<String, RepertoireReviewEntry> reviewMap;
  final String repertoireId;
  final bool lineHadMistake;
  final bool hadLearnPhaseThisSession;
  final TrainingSettings settings;
  final int sessionCorrect;
  final int sessionIncorrect;
  final int sessionStreak;
  final RepertoireReviewService reviewService;
  final String Function(DateTime date) formatRelativeDate;
  final void Function(ReviewRating rating) onRateLine;
  final VoidCallback onNextLine;

  const TrainingResultsPanel({
    super.key,
    required this.phase,
    this.currentLine,
    required this.dueQueue,
    required this.reviewMap,
    required this.repertoireId,
    required this.lineHadMistake,
    required this.hadLearnPhaseThisSession,
    required this.settings,
    required this.sessionCorrect,
    required this.sessionIncorrect,
    required this.sessionStreak,
    required this.reviewService,
    required this.formatRelativeDate,
    required this.onRateLine,
    required this.onNextLine,
  });

  @override
  State<TrainingResultsPanel> createState() => _TrainingResultsPanelState();
}

class _TrainingResultsPanelState extends State<TrainingResultsPanel> {
  bool _autoRateScheduled = false;

  bool get _shouldAutoRate =>
      !widget.settings.showRatingButtons || widget.hadLearnPhaseThisSession;

  ReviewRating get _autoRating {
    if (widget.hadLearnPhaseThisSession) return ReviewRating.good;
    return widget.lineHadMistake ? ReviewRating.again : ReviewRating.good;
  }

  @override
  void didUpdateWidget(TrainingResultsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase ||
        oldWidget.currentLine?.id != widget.currentLine?.id ||
        oldWidget.lineHadMistake != widget.lineHadMistake) {
      _autoRateScheduled = false;
    }
  }

  void _scheduleAutoRate() {
    if (!_shouldAutoRate || _autoRateScheduled) return;
    _autoRateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.phase != TrainingPhase.finished) return;
      widget.onRateLine(_autoRating);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.phase != TrainingPhase.finished) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);

    if (widget.currentLine == null || widget.dueQueue.isEmpty) {
      return AllCaughtUpPanel(
        reviewMap: widget.reviewMap,
        sessionCorrect: widget.sessionCorrect,
        sessionIncorrect: widget.sessionIncorrect,
        sessionStreak: widget.sessionStreak,
        formatRelativeDate: widget.formatRelativeDate,
      );
    }

    if (_shouldAutoRate) {
      _scheduleAutoRate();
      final message = widget.hadLearnPhaseThisSession
          ? 'Line learned — continuing...'
          : widget.lineHadMistake
          ? 'Scheduling for review...'
          : 'Line complete!';
      return Center(child: Text(message, style: theme.textTheme.bodyMedium));
    }

    final entry = widget.reviewMap[widget.currentLine?.id];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'How well did you know this?',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          TrainingRatingButtons(
            currentLine: widget.currentLine,
            repertoireId: widget.repertoireId,
            reviewMap: widget.reviewMap,
            reviewService: widget.reviewService,
            onRateLine: widget.onRateLine,
          ),
          const SizedBox(height: 16),
          if (entry != null && entry.lastReviewedUtc != null) ...[
            Text(
              'Last reviewed: ${widget.formatRelativeDate(entry.lastReviewedUtc!)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
          ],
          if (entry != null)
            Text(
              'Pass: ${entry.passCount} / Fail: ${entry.failCount}',
              style: theme.textTheme.bodySmall,
            ),
          if (!widget.settings.autoNext) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: widget.onNextLine,
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

class AllCaughtUpPanel extends StatelessWidget {
  final Map<String, RepertoireReviewEntry> reviewMap;
  final int sessionCorrect;
  final int sessionIncorrect;
  final int sessionStreak;
  final String Function(DateTime date) formatRelativeDate;

  const AllCaughtUpPanel({
    super.key,
    required this.reviewMap,
    required this.sessionCorrect,
    required this.sessionIncorrect,
    required this.sessionStreak,
    required this.formatRelativeDate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    DateTime? nextDue;
    for (final entry in reviewMap.values) {
      if (entry.dueDateUtc != null) {
        if (nextDue == null || entry.dueDateUtc!.isBefore(nextDue)) {
          nextDue = entry.dueDateUtc;
        }
      }
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline, size: 56, color: Colors.green[400]),
          const SizedBox(height: 16),
          Text('All caught up!', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (nextDue != null)
            Text(
              'Next review: ${formatRelativeDate(nextDue)}',
              style: theme.textTheme.bodySmall,
            ),
          if (sessionCorrect + sessionIncorrect > 0) ...[
            const SizedBox(height: 16),
            SessionStatsBar(
              sessionCorrect: sessionCorrect,
              sessionIncorrect: sessionIncorrect,
              sessionStreak: sessionStreak,
            ),
          ],
        ],
      ),
    );
  }
}

class TrainingRatingButtons extends StatelessWidget {
  final RepertoireLine? currentLine;
  final String repertoireId;
  final Map<String, RepertoireReviewEntry> reviewMap;
  final RepertoireReviewService reviewService;
  final void Function(ReviewRating rating) onRateLine;

  const TrainingRatingButtons({
    super.key,
    this.currentLine,
    required this.repertoireId,
    required this.reviewMap,
    required this.reviewService,
    required this.onRateLine,
  });

  static const _ratings = [
    (ReviewRating.again, 'Again', Color(0xFFE53935)),
    (ReviewRating.hard, 'Hard', Color(0xFFFB8C00)),
    (ReviewRating.good, 'Good', Color(0xFF1E88E5)),
    (ReviewRating.easy, 'Easy', Color(0xFF43A047)),
  ];

  @override
  Widget build(BuildContext context) {
    final entry = currentLine != null ? reviewMap[currentLine!.id] : null;
    final previewEntry =
        entry ??
        RepertoireReviewEntry(
          repertoireId: repertoireId,
          lineId: currentLine?.id ?? '',
          lineName: currentLine?.name ?? '',
        );

    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 8.0;
        final tileWidth = (constraints.maxWidth - spacing) / 2;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final (rating, label, color) in _ratings)
              SizedBox(
                width: tileWidth,
                child: _RatingButton(
                  rating: rating,
                  label: label,
                  color: color,
                  previewEntry: previewEntry,
                  reviewService: reviewService,
                  onRateLine: onRateLine,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _RatingButton extends StatelessWidget {
  final ReviewRating rating;
  final String label;
  final Color color;
  final RepertoireReviewEntry previewEntry;
  final RepertoireReviewService reviewService;
  final void Function(ReviewRating rating) onRateLine;

  const _RatingButton({
    required this.rating,
    required this.label,
    required this.color,
    required this.previewEntry,
    required this.reviewService,
    required this.onRateLine,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final interval = reviewService.previewInterval(previewEntry, rating);
    final intervalLabel = RepertoireReviewService.formatInterval(interval);

    return Material(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () => onRateLine(rating),
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
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
