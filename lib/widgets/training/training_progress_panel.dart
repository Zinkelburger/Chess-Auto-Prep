import 'package:flutter/material.dart';

import '../../models/repertoire_line.dart';
import '../../models/repertoire_review_entry.dart';
import '../../models/training_settings.dart';
import '../../services/training/training_phase.dart';

/// Progress bars, session stats, line progress, and train-tab footer controls.
class TrainingProgressPanel extends StatelessWidget {
  final Map<String, RepertoireReviewEntry> reviewMap;
  final int sessionCorrect;
  final int sessionIncorrect;
  final int sessionStreak;
  final RepertoireLine? currentLine;
  final TrainingPhase phase;
  final int currentMoveIndex;
  final int effectiveLineLength;
  final int dueQueueLength;

  const TrainingProgressPanel({
    super.key,
    required this.reviewMap,
    required this.sessionCorrect,
    required this.sessionIncorrect,
    required this.sessionStreak,
    this.currentLine,
    required this.phase,
    required this.currentMoveIndex,
    required this.effectiveLineLength,
    required this.dueQueueLength,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RepertoireProgressBar(reviewMap: reviewMap),
        if (sessionCorrect + sessionIncorrect > 0) ...[
          SessionStatsBar(
            sessionCorrect: sessionCorrect,
            sessionIncorrect: sessionIncorrect,
            sessionStreak: sessionStreak,
          ),
          const SizedBox(height: 8),
        ],
        if (currentLine != null) ...[
          Text(
            currentLine!.name,
            style: theme.textTheme.titleSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          LineProgressIndicator(
            phase: phase,
            currentMoveIndex: currentMoveIndex,
            effectiveLineLength: effectiveLineLength,
          ),
          const Divider(height: 16),
        ],
      ],
    );
  }
}

class TrainingBottomControls extends StatelessWidget {
  final TrainingSettings settings;
  final int dueQueueLength;
  final ValueChanged<bool> onAutoNextChanged;

  const TrainingBottomControls({
    super.key,
    required this.settings,
    required this.dueQueueLength,
    required this.onAutoNextChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('Auto-next', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(width: 8),
        SizedBox(
          height: 24,
          child: Switch(value: settings.autoNext, onChanged: onAutoNextChanged),
        ),
        const Spacer(),
        Text(
          '$dueQueueLength due',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class RepertoireProgressBar extends StatelessWidget {
  final Map<String, RepertoireReviewEntry> reviewMap;

  const RepertoireProgressBar({super.key, required this.reviewMap});

  @override
  Widget build(BuildContext context) {
    if (reviewMap.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    int unseen = 0;
    int due = 0;
    int practiced = 0;
    for (final entry in reviewMap.values) {
      if (entry.isNew) {
        unseen++;
      } else if (entry.isDue) {
        due++;
      } else {
        practiced++;
      }
    }

    final total = unseen + due + practiced;
    if (total == 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 6,
              child: Row(
                children: [
                  if (practiced > 0)
                    Expanded(
                      flex: practiced,
                      child: Container(color: Colors.green),
                    ),
                  if (due > 0)
                    Expanded(
                      flex: due,
                      child: Container(color: Colors.orange),
                    ),
                  if (unseen > 0)
                    Expanded(
                      flex: unseen,
                      child: Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          DefaultTextStyle(
            style: theme.textTheme.bodySmall!,
            child: Row(
              children: [
                Text(
                  '$practiced practiced',
                  style: const TextStyle(color: Colors.green, fontSize: 11),
                ),
                const SizedBox(width: 8),
                Text(
                  '$due due',
                  style: const TextStyle(color: Colors.orange, fontSize: 11),
                ),
                const SizedBox(width: 8),
                Text(
                  '$unseen unseen',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SessionStatsBar extends StatelessWidget {
  final int sessionCorrect;
  final int sessionIncorrect;
  final int sessionStreak;

  const SessionStatsBar({
    super.key,
    required this.sessionCorrect,
    required this.sessionIncorrect,
    required this.sessionStreak,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = sessionCorrect + sessionIncorrect;
    final accuracy = total > 0 ? (sessionCorrect * 100 ~/ total) : 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _StatItem(
            Icons.check_circle_outline,
            '$sessionCorrect',
            Colors.green,
            theme,
          ),
          _StatItem(
            Icons.cancel_outlined,
            '$sessionIncorrect',
            Colors.red,
            theme,
          ),
          _StatItem(
            Icons.percent,
            '$accuracy%',
            theme.colorScheme.onSurface,
            theme,
          ),
          _StatItem(
            Icons.local_fire_department,
            '$sessionStreak',
            Colors.orange,
            theme,
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String value;
  final Color color;
  final ThemeData theme;

  const _StatItem(this.icon, this.value, this.color, this.theme);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(value, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}

class LineProgressIndicator extends StatelessWidget {
  final TrainingPhase phase;
  final int currentMoveIndex;
  final int effectiveLineLength;

  const LineProgressIndicator({
    super.key,
    required this.phase,
    required this.currentMoveIndex,
    required this.effectiveLineLength,
  });

  @override
  Widget build(BuildContext context) {
    if (effectiveLineLength <= 0) return const SizedBox.shrink();

    final progress = currentMoveIndex / effectiveLineLength;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Move $currentMoveIndex / $effectiveLineLength',
              style: theme.textTheme.bodySmall,
            ),
            const Spacer(),
            if (phase == TrainingPhase.learning)
              Text(
                'Learning',
                style: TextStyle(color: Colors.blue[400], fontSize: 12),
              ),
            if (phase == TrainingPhase.drilling)
              Text(
                'Drilling',
                style: TextStyle(color: Colors.orange[400], fontSize: 12),
              ),
            if (phase == TrainingPhase.replaying)
              Text(
                'Replaying',
                style: TextStyle(color: Colors.red[400], fontSize: 12),
              ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: progress.clamp(0.0, 1.0),
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
      ],
    );
  }
}
