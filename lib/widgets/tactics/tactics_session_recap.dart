import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// End-of-session recap card: outcome counts, accuracy, time, and a
/// "retry mistakes" entry point.  Shown in the Tactic tab once the session
/// queue is exhausted.
class TacticsSessionRecap extends StatelessWidget {
  const TacticsSessionRecap({
    super.key,
    required this.solved,
    required this.failed,
    required this.skipped,
    required this.totalTimeSeconds,
    this.onRetryMistakes,
    required this.onDone,
  });

  /// Puzzles solved outright on the first attempt.
  final int solved;

  /// Puzzles failed on the first attempt.
  final int failed;

  /// Puzzles navigated past without a scored attempt (includes revealing
  /// the solution).
  final int skipped;

  /// Total attempt time recorded this session, in seconds.
  final double totalTimeSeconds;

  /// Starts a new session over the failed + skipped puzzles; null when
  /// everything was solved (button hidden).
  final VoidCallback? onRetryMistakes;

  final VoidCallback onDone;

  int get _attempted => solved + failed;

  int get _mistakes => failed + skipped;

  String _formatSeconds(double seconds) {
    if (seconds >= 60) {
      final m = seconds ~/ 60;
      final s = (seconds % 60).round();
      return '${m}m ${s}s';
    }
    return '${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)}s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accuracy = _attempted > 0 ? solved / _attempted : 0.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.flag_circle_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Session complete',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                _StatTile(
                  icon: Icons.check_circle_outline,
                  color: AppColors.success,
                  count: solved,
                  label: 'Solved',
                ),
                _StatTile(
                  icon: Icons.cancel_outlined,
                  color: AppColors.danger,
                  count: failed,
                  label: 'Failed',
                ),
                if (skipped > 0)
                  _StatTile(
                    icon: Icons.skip_next_outlined,
                    color: AppColors.onSurfaceMuted,
                    count: skipped,
                    label: 'Skipped',
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (_attempted > 0)
              Text(
                'Accuracy ${(accuracy * 100).toStringAsFixed(0)}%'
                ' · ${_formatSeconds(totalTimeSeconds)} total'
                ' · avg ${_formatSeconds(totalTimeSeconds / _attempted)} per puzzle',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                if (onRetryMistakes != null) ...[
                  FilledButton.icon(
                    onPressed: onRetryMistakes,
                    icon: const Icon(Icons.replay, size: 18),
                    label: Text('Retry mistakes ($_mistakes)'),
                  ),
                  const SizedBox(width: 12),
                ],
                OutlinedButton(onPressed: onDone, child: const Text('Done')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.color,
    required this.count,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final int count;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 4),
          Text(
            '$count',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
