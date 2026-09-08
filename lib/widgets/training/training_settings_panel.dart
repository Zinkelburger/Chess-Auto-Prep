import 'package:flutter/material.dart';

import '../../models/training_settings.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../settings/settings_widgets.dart';
import '../settings/settings_navigation.dart';
import '../common/choice_field.dart';

/// Focused preference pages, using the same rows and cards as app settings.
class TrainingSettingsPanel extends StatefulWidget {
  final TrainingSettings settings;
  final VoidCallback onQueueSettingsChanged;
  final VoidCallback onSettingsChanged;
  final VoidCallback? onChapterSettingsChanged;
  final TrainingMode trainingMode;
  final RepetitionMode repetitionMode;
  final ValueChanged<TrainingMode> onTrainingModeChanged;
  final ValueChanged<RepetitionMode> onRepetitionModeChanged;
  final bool? playingWhite;
  final VoidCallback? onChangePlayingSide;
  final VoidCallback? onOpenChapterSetup;
  final VoidCallback? onOpenAppSettings;
  final bool chaptersDeclined;

  const TrainingSettingsPanel({
    super.key,
    required this.settings,
    required this.onQueueSettingsChanged,
    required this.onSettingsChanged,
    this.onChapterSettingsChanged,
    required this.trainingMode,
    required this.repetitionMode,
    required this.onTrainingModeChanged,
    required this.onRepetitionModeChanged,
    this.playingWhite,
    this.onChangePlayingSide,
    this.onOpenChapterSetup,
    this.onOpenAppSettings,
    this.chaptersDeclined = false,
  });

  @override
  State<TrainingSettingsPanel> createState() => _TrainingSettingsPanelState();
}

class _TrainingSettingsPanelState extends State<TrainingSettingsPanel> {
  int _selected = 0;
  TrainingSettings get settings => widget.settings;
  static const _sections = [
    (
      label: 'Session',
      icon: Icons.school_outlined,
      description: 'Choose what to practise and how much to do.',
    ),
    (
      label: 'Learning',
      icon: Icons.psychology_outlined,
      description: 'Choose how moves are learned and reviewed.',
    ),
    (
      label: 'Playback',
      icon: Icons.play_circle_outline,
      description: 'Set the pace and when to move on.',
    ),
    (
      label: 'Material',
      icon: Icons.menu_book_outlined,
      description: 'The side you play and how your lines are listed.',
    ),
  ];

  void _change(
    VoidCallback update, {
    bool queue = false,
    bool chapters = false,
  }) {
    if (!mounted) return;
    update();
    settings.saveSoon();
    if (queue) widget.onQueueSettingsChanged();
    if (chapters) widget.onChapterSettingsChanged?.call();
    widget.onSettingsChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final sharedChapter = SettingsChapterScope.maybeOf(context);
    if (sharedChapter != null) {
      return ListView(
        key: ValueKey(sharedChapter),
        padding: const EdgeInsets.all(24),
        children: switch (sharedChapter) {
          0 => _session(),
          1 => _learning(),
          2 => _playback(),
          _ => _material(),
        },
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final section = _sections[_selected];
        final content = Expanded(
          child: ListView(
            key: ValueKey(_selected),
            padding: EdgeInsets.all(compact ? 20 : 28),
            children: [
              Text(section.label, style: AppTextStyles.title),
              const SizedBox(height: 8),
              Text(section.description, style: AppTextStyles.muted),
              const SizedBox(height: 24),
              ...switch (_selected) {
                0 => _session(),
                1 => _learning(),
                2 => _playback(),
                _ => _material(),
              },
            ],
          ),
        );
        if (compact) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: ChoiceField<int>(
                  key: const Key('training-settings-section'),
                  value: _selected,
                  label: 'Section',
                  items: [
                    for (var i = 0; i < _sections.length; i++)
                      ChoiceItem(value: i, label: _sections[i].label),
                  ],
                  onChanged: (value) {
                    if (!mounted) return;
                    setState(() => _selected = value);
                  },
                ),
              ),
              content,
              if (widget.onOpenAppSettings != null)
                TextButton(
                  onPressed: widget.onOpenAppSettings,
                  child: const Text('App settings…'),
                ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 200,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (var i = 0; i < _sections.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        key: Key('training-settings-nav-$i'),
                        selected: _selected == i,
                        selectedTileColor: AppColors.accent.withValues(
                          alpha: 0.12,
                        ),
                        selectedColor: AppColors.ink,
                        iconColor: AppColors.onSurfaceMuted,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        leading: Icon(_sections[i].icon, size: 20),
                        title: Text(
                          _sections[i].label,
                          style: _selected == i
                              ? AppTextStyles.bodyStrong
                              : AppTextStyles.body,
                        ),
                        onTap: () {
                          if (!mounted) return;
                          setState(() => _selected = i);
                        },
                      ),
                    ),
                  if (widget.onOpenAppSettings != null) ...[
                    const Divider(height: 32),
                    ListTile(
                      title: const Text(
                        'App settings…',
                        style: AppTextStyles.body,
                      ),
                      onTap: widget.onOpenAppSettings,
                    ),
                  ],
                ],
              ),
            ),
            const VerticalDivider(width: 1, color: AppColors.divider),
            content,
          ],
        );
      },
    );
  }

  List<Widget> _session() => [
    SettingsGroup(
      title: 'Practice',
      icon: Icons.school_outlined,
      children: [
        SettingsChoiceTile<TrainingMode>(
          label: 'What to train',
          description:
              'Learn repertoire moves first, or solve tactics without seeing the answer.',
          value: widget.trainingMode,
          items: [for (final mode in TrainingMode.values) (mode, mode.label)],
          onChanged: widget.onTrainingModeChanged,
        ),
        SettingsChoiceTile<RepetitionMode>(
          label: 'Review schedule',
          description:
              'Spaced repetition brings lines back when due. One pass visits every line once.',
          value: widget.repetitionMode,
          items: const [
            (RepetitionMode.spaced, 'Spaced repetition'),
            (RepetitionMode.linear, 'One pass'),
          ],
          onChanged: widget.onRepetitionModeChanged,
        ),
      ],
    ),
    if (widget.repetitionMode != RepetitionMode.linear)
      SettingsGroup(
        title: 'Session size',
        icon: Icons.format_list_numbered,
        subtitle: 'Lines per session. Use 0 for no limit.',
        children: [
          _number(
            'New lines',
            settings.newLinesPerSession,
            0,
            500,
            (n) => settings.newLinesPerSession = n,
          ),
          _number(
            'Reviews',
            settings.reviewsPerSession,
            0,
            500,
            (n) => settings.reviewsPerSession = n,
          ),
        ],
      ),
  ];

  List<Widget> _learning() => [
    SettingsGroup(
      title: 'Remembering moves',
      icon: Icons.psychology_outlined,
      children: [
        _number(
          'Correct answers to memorize',
          settings.correctStreakThreshold,
          1,
          10,
          (n) => settings.correctStreakThreshold = n,
          description: 'Consecutive correct answers needed for each move.',
        ),
        SettingsValueRow(
          label: 'Drill depth',
          description:
              'Train the first N moves. Leave empty for the whole line.',
          control: SizedBox(
            width: 100,
            child: TextFormField(
              key: const Key('training-depth'),
              initialValue: settings.trainingDepth?.toString() ?? '',
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                hintText: 'All',
                border: OutlineInputBorder(),
              ),
              onChanged: (text) {
                final n = int.tryParse(text);
                if (text.trim().isEmpty || (n != null && n >= 1 && n <= 200)) {
                  _change(
                    () =>
                        settings.trainingDepth = text.trim().isEmpty ? null : n,
                  );
                }
              },
            ),
          ),
        ),
        _toggle(
          'Replay missed moves',
          'Practise mistakes again before rating the line.',
          settings.wrongMoveReplay,
          (v) => settings.wrongMoveReplay = v,
        ),
        _toggle(
          'Rate difficulty yourself',
          'Choose Again, Hard, Good or Easy. Otherwise your mistakes set the rating.',
          settings.showRatingButtons,
          (v) => settings.showRatingButtons = v,
        ),
        if (widget.repetitionMode != RepetitionMode.linear)
          SettingsChoiceTile<ReviewOrder>(
            label: 'Review order',
            value: settings.reviewOrder,
            items: [
              for (final order in ReviewOrder.values) (order, order.label),
            ],
            onChanged: (v) =>
                _change(() => settings.reviewOrder = v, queue: true),
          ),
      ],
    ),
  ];

  List<Widget> _playback() => [
    SettingsGroup(
      title: 'Advancing',
      icon: Icons.play_circle_outline,
      children: [
        _toggle(
          'Wait for Next',
          'When learning, press Next or Space before being quizzed.',
          settings.learnRequiresClick,
          (v) => settings.learnRequiresClick = v,
        ),
        if (!settings.learnRequiresClick)
          _number(
            'Seconds before quiz',
            settings.learnDelaySec,
            1,
            15,
            (n) => settings.learnDelaySec = n,
          ),
        _toggle(
          'Start the next line automatically',
          'Continue after completing and rating a line.',
          settings.autoNext,
          (v) => settings.autoNext = v,
        ),
        _speed(
          'Opponent move delay',
          settings.moveSpeedMs,
          (v) => settings.moveSpeedMs = v,
        ),
      ],
    ),
    SettingsGroup(
      title: 'Opening introduction',
      icon: Icons.fast_forward_outlined,
      children: [
        _toggle(
          'Start at the first comment',
          'Play the uncommented opening moves automatically before training.',
          settings.skipToFirstComment,
          (v) => settings.skipToFirstComment = v,
        ),
        if (settings.skipToFirstComment)
          _speed(
            'Introduction move delay',
            settings.introSpeedMs,
            (v) => settings.introSpeedMs = v,
          ),
      ],
    ),
  ];

  List<Widget> _material() => [
    if (widget.playingWhite != null)
      SettingsGroup(
        title: 'Playing side',
        icon: Icons.contrast,
        children: [
          SettingsValueRow(
            label: 'You play ${widget.playingWhite! ? 'White' : 'Black'}',
            description:
                'Change this if the trainer asks you for the opponent’s moves.',
            control: OutlinedButton(
              onPressed: widget.onChangePlayingSide,
              child: const Text('Change side…'),
            ),
          ),
        ],
      ),
    SettingsGroup(
      title: 'Chapter grouping',
      icon: Icons.menu_book_outlined,
      subtitle:
          'Chapters are sections of your material. Open one in the list to practise its lines. These options only change the trainer’s list; your PGN stays intact.',
      children: [
        if (widget.chaptersDeclined)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'This file is set to one flat list. Preview its chapter grouping to restore chapters.',
              style: AppTextStyles.muted,
            ),
          ),
        if (!widget.chaptersDeclined)
          SettingsChoiceTile<ChapterGroupingMode>(
            label: 'Group lines by',
            value: settings.chapterGrouping,
            items: const [
              (ChapterGroupingMode.auto, 'Chapters in the file'),
              (ChapterGroupingMode.namePrefix, 'Line name prefix'),
              (ChapterGroupingMode.off, 'One flat list'),
            ],
            onChanged: (v) =>
                _change(() => settings.chapterGrouping = v, chapters: true),
          ),
        if (!widget.chaptersDeclined &&
            settings.chapterGrouping == ChapterGroupingMode.namePrefix)
          SettingsValueRow(
            label: 'Name separator',
            description: 'For “Benoni #3”, use # to group under Benoni.',
            control: SizedBox(
              width: 100,
              child: TextFormField(
                initialValue: settings.chapterDelimiter,
                maxLength: 3,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
                onChanged: (v) {
                  if (v.isNotEmpty) {
                    _change(
                      () => settings.chapterDelimiter = v,
                      chapters: true,
                    );
                  }
                },
              ),
            ),
          ),
        if (widget.onOpenChapterSetup != null)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: widget.onOpenChapterSetup,
                child: const Text('Preview chapter grouping…'),
              ),
            ),
          ),
      ],
    ),
  ];

  Widget _number(
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> update, {
    String? description,
  }) => SettingsValueRow(
    label: label,
    description: description,
    control: SizedBox(
      width: 100,
      child: TextFormField(
        key: ValueKey(label),
        initialValue: '$value',
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(border: OutlineInputBorder()),
        onChanged: (text) {
          final n = int.tryParse(text);
          if (n != null && n >= min && n <= max) _change(() => update(n));
        },
      ),
    ),
  );

  Widget _toggle(
    String label,
    String description,
    bool value,
    ValueChanged<bool> update,
  ) => SettingsValueRow(
    label: label,
    description: description,
    control: Switch(value: value, onChanged: (v) => _change(() => update(v))),
  );

  Widget _speed(String label, int value, ValueChanged<int> update) =>
      SettingsSliderTile(
        label: label,
        value: value,
        min: 200,
        max: 2000,
        divisions: 18,
        suffix: 'ms',
        onChanged: (v) => _change(() => update(v)),
      );
}
