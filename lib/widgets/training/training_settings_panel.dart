import 'package:flutter/material.dart';

import '../../models/repertoire_line.dart';
import '../../models/repertoire_review_entry.dart';
import '../../models/training_settings.dart';
import '../../services/repertoire_review_service.dart';
import '../shortcut_tooltip.dart';

/// Settings tab for repertoire training (depth, review order, learn mode).
class TrainingSettingsPanel extends StatelessWidget {
  final TrainingSettings settings;
  final TextEditingController repetitionsController;
  final TextEditingController depthController;
  final TextEditingController delayController;
  final List<RepertoireLine> lines;
  final Map<String, RepertoireReviewEntry> reviewMap;
  final RepertoireReviewService reviewService;
  final void Function(List<RepertoireLine> dueQueue) onDueQueueUpdated;
  final VoidCallback onSettingsChanged;

  const TrainingSettingsPanel({
    super.key,
    required this.settings,
    required this.repetitionsController,
    required this.depthController,
    required this.delayController,
    required this.lines,
    required this.reviewMap,
    required this.reviewService,
    required this.onDueQueueUpdated,
    required this.onSettingsChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Settings', style: theme.textTheme.titleMedium),
          const SizedBox(height: 20),
          Text('Repetitions to memorize', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'A move is "memorized" after you get it right this '
            'many times in a row. (1–10)',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 80,
            child: TextField(
              controller: repetitionsController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: '3',
              ),
              onChanged: (value) {
                final n = int.tryParse(value);
                if (n != null && n >= 1 && n <= 10) {
                  settings.correctStreakThreshold = n;
                  settings.save();
                  onSettingsChanged();
                }
              },
            ),
          ),
          const SizedBox(height: 24),
          Text('Drill depth (moves)', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Only drill the first N moves of each line. '
            'Leave empty to drill the entire line.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 80,
            child: TextField(
              controller: depthController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: 'All',
              ),
              onChanged: (value) {
                if (value.trim().isEmpty) {
                  settings.trainingDepth = null;
                  settings.save();
                  onSettingsChanged();
                  return;
                }
                final n = int.tryParse(value);
                if (n != null && n >= 1 && n <= 200) {
                  settings.trainingDepth = n;
                  settings.save();
                  onSettingsChanged();
                }
              },
            ),
          ),
          const SizedBox(height: 24),
          Text('Review order', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'How due lines are ordered during training.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<ReviewOrder>(
            initialValue: settings.reviewOrder,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: ReviewOrder.values
                .map(
                  (order) => DropdownMenuItem(
                    value: order,
                    child: Text(order.label),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              settings.reviewOrder = value;
              final dueQueue = reviewService.orderLinesForReview(
                lines,
                reviewMap,
                settings.reviewOrder,
              );
              onDueQueueUpdated(dueQueue);
              settings.save();
              onSettingsChanged();
            },
          ),
          const SizedBox(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title:
                Text('Replay missed moves', style: theme.textTheme.titleSmall),
            subtitle: const Text(
              'After a line, replay every move you got wrong '
              'before rating.',
            ),
            value: settings.wrongMoveReplay,
            onChanged: (v) {
              settings.wrongMoveReplay = v;
              settings.save();
              onSettingsChanged();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Self-rate difficulty (1-4)',
                style: theme.textTheme.titleSmall),
            subtitle: const Text(
              'Show Again/Hard/Good/Easy buttons after each line. '
              'If off, difficulty is determined automatically from '
              'your mistakes.',
            ),
            value: settings.showRatingButtons,
            onChanged: (v) {
              settings.showRatingButtons = v;
              settings.save();
              onSettingsChanged();
            },
          ),
          const SizedBox(height: 24),
          Text('Move speed', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'How long opponent moves are shown before advancing. '
            '${settings.moveSpeedMs}ms',
            style: theme.textTheme.bodySmall,
          ),
          Slider(
            value: settings.moveSpeedMs.toDouble(),
            min: 200,
            max: 2000,
            divisions: 18,
            label: '${settings.moveSpeedMs}ms',
            onChanged: (v) {
              settings.moveSpeedMs = v.round();
              settings.save();
              onSettingsChanged();
            },
          ),
          const Divider(height: 32),
          Text('Learning new lines', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          ShortcutTooltip(
            description: 'Toggle auto-advance when learning new lines',
            shortcut: 'J',
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Manual advance', style: theme.textTheme.titleSmall),
              subtitle: const Text(
                'Press Next (or Space) to see the next move when '
                'learning. Turn off to auto-advance after a delay.',
              ),
              value: settings.learnRequiresClick,
              onChanged: (v) {
                settings.learnRequiresClick = v;
                settings.save();
                onSettingsChanged();
              },
            ),
          ),
          if (!settings.learnRequiresClick) ...[
            const SizedBox(height: 12),
            Text('Auto-advance delay (seconds)',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Seconds to show each annotated move before '
              'advancing. (1–15)',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 80,
              child: TextField(
                controller: delayController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: '3',
                ),
                onChanged: (value) {
                  final n = int.tryParse(value);
                  if (n != null && n >= 1 && n <= 15) {
                    settings.learnDelaySec = n;
                    settings.save();
                    onSettingsChanged();
                  }
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
