/// A slim banner over the builder while a planned build runs: which chapter
/// is building, and the two things you can do about it — pause the engine,
/// or finish later (stop after this chapter; the remaining chapters stay in
/// the outline as empty chapters you can generate into any time).
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../controllers/plan_runner.dart';

class PlanRunnerBanner extends StatelessWidget {
  const PlanRunnerBanner({
    super.key,
    required this.runner,
    required this.isPaused,
    required this.onPause,
    required this.onResume,
  });

  final PlanRunner runner;
  final bool isPaused;
  final VoidCallback onPause;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final items = runner.items;
    final i = runner.currentIndex;
    final current = i >= 0 && i < items.length ? items[i] : null;
    final done = runner.doneCount;
    final label = current == null
        ? 'Creating chapters…'
        : '${isPaused ? 'Paused' : 'Building'} ${current.chapter.name} '
              '· ${done + 1} of ${items.length}';
    return Material(
      color: AppColors.accent.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.route_outlined, size: 16, color: AppColors.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (current != null)
              TextButton(
                onPressed: isPaused ? onResume : onPause,
                child: Text(isPaused ? 'Resume' : 'Pause'),
              ),
            TextButton(
              onPressed: runner.cancel,
              child: const Text('Finish later'),
            ),
          ],
        ),
      ),
    );
  }
}
