import 'package:flutter/material.dart';

import '../../utils/app_shortcuts.dart';

import '../../models/training_settings.dart';
import '../shortcut_tooltip.dart';

/// Settings tab for repertoire training (what is trained, scheduling, depth,
/// learn mode).
class TrainingSettingsPanel extends StatelessWidget {
  final TrainingSettings settings;
  final TextEditingController repetitionsController;
  final TextEditingController depthController;
  final TextEditingController delayController;

  /// Rebuilds the due queue after a change that reorders or refilters it.
  final VoidCallback onQueueSettingsChanged;
  final VoidCallback onSettingsChanged;

  /// Called when the chapter grouping source or delimiter changes, so the
  /// active chapter filter can reset and the queue rebuild.
  final VoidCallback? onChapterSettingsChanged;

  /// What is trained (repertoire lines vs cold tactics) and how completions
  /// schedule (spaced repetition vs one pass through every line).
  final TrainingMode trainingMode;
  final RepetitionMode repetitionMode;
  final ValueChanged<TrainingMode> onTrainingModeChanged;
  final ValueChanged<RepetitionMode> onRepetitionModeChanged;

  const TrainingSettingsPanel({
    super.key,
    required this.settings,
    required this.repetitionsController,
    required this.depthController,
    required this.delayController,
    required this.onQueueSettingsChanged,
    required this.onSettingsChanged,
    this.onChapterSettingsChanged,
    required this.trainingMode,
    required this.repetitionMode,
    required this.onTrainingModeChanged,
    required this.onRepetitionModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What to train', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Repertoire lines are walked through first, then quizzed. '
            'Tactics are always quizzed cold — showing the solution first '
            'would spoil the puzzle.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<TrainingMode>(
            segments: [
              for (final mode in TrainingMode.values)
                ButtonSegment(value: mode, label: Text(mode.label)),
            ],
            selected: {trainingMode},
            showSelectedIcon: false,
            onSelectionChanged: (selection) =>
                onTrainingModeChanged(selection.first),
          ),
          const SizedBox(height: 24),
          Text('How to schedule', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Spaced repetition brings each line back when it is due. '
            'Linear runs through every line once, in order, without '
            'scheduling anything.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<RepetitionMode>(
            segments: [
              for (final mode in RepetitionMode.values)
                ButtonSegment(value: mode, label: Text(mode.label)),
            ],
            selected: {repetitionMode},
            showSelectedIcon: false,
            onSelectionChanged: (selection) =>
                onRepetitionModeChanged(selection.first),
          ),
          const Divider(height: 32),
          Text('Session size', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'How much one press of Learn or Review covers before calling it a '
            'sitting. A bought course is hundreds of lines; the cap is what '
            'turns it into something you can finish. 0 means no limit.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _SessionSizeField(
                label: 'New lines',
                value: settings.newLinesPerSession,
                onChanged: (n) {
                  settings.newLinesPerSession = n;
                  settings.saveSoon();
                  onSettingsChanged();
                },
              ),
              const SizedBox(width: 16),
              _SessionSizeField(
                label: 'Reviews',
                value: settings.reviewsPerSession,
                onChanged: (n) {
                  settings.reviewsPerSession = n;
                  settings.saveSoon();
                  onSettingsChanged();
                },
              ),
            ],
          ),
          const SizedBox(height: 24),
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
                  settings.saveSoon();
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
                  settings.saveSoon();
                  onSettingsChanged();
                  return;
                }
                final n = int.tryParse(value);
                if (n != null && n >= 1 && n <= 200) {
                  settings.trainingDepth = n;
                  settings.saveSoon();
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
                  (order) =>
                      DropdownMenuItem(value: order, child: Text(order.label)),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              settings.reviewOrder = value;
              settings.saveSoon();
              onQueueSettingsChanged();
              onSettingsChanged();
            },
          ),
          const SizedBox(height: 24),
          Text('Chapters', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'How lines are grouped into chapters in the line list.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<ChapterGroupingMode>(
            initialValue: settings.chapterGrouping,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: ChapterGroupingMode.values
                .map(
                  (mode) => DropdownMenuItem(
                    value: mode,
                    child: Tooltip(
                      message: mode.description,
                      waitDuration: const Duration(milliseconds: 400),
                      child: Text(mode.label),
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              settings.chapterGrouping = value;
              settings.saveSoon();
              onChapterSettingsChanged?.call();
              onSettingsChanged();
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 80,
                child: TextFormField(
                  initialValue: settings.chapterDelimiter,
                  enabled:
                      settings.chapterGrouping ==
                      ChapterGroupingMode.namePrefix,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    labelText: 'Delimiter',
                  ),
                  maxLength: 3,
                  buildCounter:
                      (
                        context, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) => null,
                  onChanged: (value) {
                    if (value.isEmpty) return;
                    settings.chapterDelimiter = value;
                    settings.saveSoon();
                    onChapterSettingsChanged?.call();
                    onSettingsChanged();
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'For line-name prefix grouping: the chapter is everything '
                  'before this character (e.g. "#" for "Benoni #3").',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Replay missed moves',
              style: theme.textTheme.titleSmall,
            ),
            subtitle: const Text(
              'After a line, replay every move you got wrong '
              'before rating.',
            ),
            value: settings.wrongMoveReplay,
            onChanged: (v) {
              settings.wrongMoveReplay = v;
              settings.saveSoon();
              onSettingsChanged();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Self-rate difficulty (1-4)',
              style: theme.textTheme.titleSmall,
            ),
            subtitle: const Text(
              'Show Again/Hard/Good/Easy buttons after each line. '
              'If off, difficulty is determined automatically from '
              'your mistakes.',
            ),
            value: settings.showRatingButtons,
            onChanged: (v) {
              settings.showRatingButtons = v;
              settings.saveSoon();
              onSettingsChanged();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Skip ahead to the first comment',
              style: theme.textTheme.titleSmall,
            ),
            subtitle: const Text(
              'Auto-play the opening moves before the first commented '
              'move instead of quizzing them, so you watch the line take '
              'shape. Training starts at the first comment.',
            ),
            value: settings.skipToFirstComment,
            onChanged: (v) {
              settings.skipToFirstComment = v;
              settings.saveSoon();
              onSettingsChanged();
            },
          ),
          if (settings.skipToFirstComment) ...[
            const SizedBox(height: 8),
            Text('Intro playback speed', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Delay between auto-played opening moves. '
              '${settings.introSpeedMs}ms',
              style: theme.textTheme.bodySmall,
            ),
            Slider(
              value: settings.introSpeedMs.toDouble(),
              min: 200,
              max: 2000,
              divisions: 18,
              label: '${settings.introSpeedMs}ms',
              onChanged: (v) {
                settings.introSpeedMs = v.round();
                settings.saveSoon();
                onSettingsChanged();
              },
            ),
          ],
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
              settings.saveSoon();
              onSettingsChanged();
            },
          ),
          const Divider(height: 32),
          Text('Learning new lines', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          ShortcutTooltip(
            description: 'Toggle auto-advance when learning new lines',
            shortcut: AppShortcut.autoAdvance,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Manual advance', style: theme.textTheme.titleSmall),
              subtitle: const Text(
                'Press Next (or Space) before each of your moves is quizzed '
                'when learning. Turn off to be quizzed after a delay instead.',
              ),
              value: settings.learnRequiresClick,
              onChanged: (v) {
                settings.learnRequiresClick = v;
                settings.saveSoon();
                onSettingsChanged();
              },
            ),
          ),
          if (!settings.learnRequiresClick) ...[
            const SizedBox(height: 12),
            Text(
              'Auto-advance delay (seconds)',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Seconds each of your moves stays on the board before you '
              'are asked to play it. (1–15)',
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
                    settings.saveSoon();
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

/// One "lines per sitting" number. Stateful so typing "1" on the way to "12"
/// does not immediately rewrite the field from the clamped setting.
class _SessionSizeField extends StatefulWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  const _SessionSizeField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_SessionSizeField> createState() => _SessionSizeFieldState();
}

class _SessionSizeFieldState extends State<_SessionSizeField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value.toString(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      child: TextField(
        controller: _controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          labelText: widget.label,
        ),
        onChanged: (value) {
          final n = int.tryParse(value.trim());
          if (n != null && n >= 0 && n <= 500) widget.onChanged(n);
        },
      ),
    );
  }
}
