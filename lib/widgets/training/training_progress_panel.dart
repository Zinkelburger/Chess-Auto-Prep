import 'package:flutter/material.dart';

import '../../models/training_settings.dart';
import '../../theme/app_colors.dart';
import '../labeled_toggle.dart';

/// Footer of the Train tab: auto-next plus how much is left in this run.
class TrainingBottomControls extends StatelessWidget {
  final TrainingSettings settings;
  final int dueQueueLength;
  final ValueChanged<bool> onAutoNextChanged;

  /// Suffix after the queue count: 'due' (spaced) or 'left' (linear).
  final String queueLabel;

  const TrainingBottomControls({
    super.key,
    required this.settings,
    required this.dueQueueLength,
    required this.onAutoNextChanged,
    this.queueLabel = 'due',
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AppSwitch(
          label: 'Auto-next',
          value: settings.autoNext,
          onChanged: onAutoNextChanged,
        ),
        const Spacer(),
        Text(
          '$dueQueueLength $queueLabel',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Correct / incorrect / accuracy / streak for the current sitting.
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
            AppColors.success,
          ),
          _StatItem(
            Icons.cancel_outlined,
            '$sessionIncorrect',
            AppColors.danger,
          ),
          _StatItem(Icons.percent, '$accuracy%', theme.colorScheme.onSurface),
          _StatItem(
            Icons.local_fire_department,
            '$sessionStreak',
            AppColors.starAccent,
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

  const _StatItem(this.icon, this.value, this.color);

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
