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

  @override
  void didUpdateWidget(TrainingResultsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase ||
        oldWidget.currentLine?.id != widget.currentLine?.id ||
        oldWidget.lineHadMistake != widget.lineHadMistake) {
      _autoRateScheduled = false;
    }
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

    if (!widget.settings.showRatingButtons) {
      if (!_autoRateScheduled) {
        _autoRateScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || widget.phase != TrainingPhase.finished) return;
          final autoRating =
              widget.lineHadMistake ? ReviewRating.again : ReviewRating.good;
          widget.onRateLine(autoRating);
        });
      }
      return Center(
        child: Text(
          widget.lineHadMistake ? 'Scheduling for review...' : 'Line complete!',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    final entry = widget.reviewMap[widget.currentLine?.id];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How well did you know this?',
              style: theme.textTheme.titleSmall),
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
            Text('Next review: ${formatRelativeDate(nextDue)}',
                style: theme.textTheme.bodySmall),
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

  @override
  Widget build(BuildContext context) {
    final entry = currentLine != null ? reviewMap[currentLine!.id] : null;
    final previewEntry = entry ??
        RepertoireReviewEntry(
          repertoireId: repertoireId,
          lineId: currentLine?.id ?? '',
          lineName: currentLine?.name ?? '',
        );

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _RatingButton(
          rating: ReviewRating.again,
          label: 'Again',
          color: Colors.red,
          previewEntry: previewEntry,
          reviewService: reviewService,
          onRateLine: onRateLine,
        ),
        _RatingButton(
          rating: ReviewRating.hard,
          label: 'Hard',
          color: Colors.orange,
          previewEntry: previewEntry,
          reviewService: reviewService,
          onRateLine: onRateLine,
        ),
        _RatingButton(
          rating: ReviewRating.good,
          label: 'Good',
          color: Colors.blue,
          previewEntry: previewEntry,
          reviewService: reviewService,
          onRateLine: onRateLine,
        ),
        _RatingButton(
          rating: ReviewRating.easy,
          label: 'Easy',
          color: Colors.green,
          previewEntry: previewEntry,
          reviewService: reviewService,
          onRateLine: onRateLine,
        ),
      ],
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
    final interval = reviewService.previewInterval(previewEntry, rating);
    final intervalLabel = RepertoireReviewService.formatInterval(interval);

    return Tooltip(
      message: label,
      child: OutlinedButton(
        onPressed: () => onRateLine(rating),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            Text(intervalLabel,
                style: TextStyle(
                    fontSize: 10, color: color.withValues(alpha: 0.7))),
          ],
        ),
      ),
    );
  }
}
