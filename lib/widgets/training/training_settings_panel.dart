import 'dart:async';
import 'package:flutter/material.dart';

import '../../features/training/models/training_settings.dart';
import '../../theme/app_text_styles.dart';
import '../settings/settings_widgets.dart';
import '../common/choice_field.dart';

/// Focused preference pages, using the same rows and cards as app settings.
class TrainingSettingsPanel extends StatefulWidget {
  final TrainingSettings settings;
  final Future<void> Function() saveSettings;
  final VoidCallback onQueueSettingsChanged;
  final VoidCallback onSettingsChanged;
  final VoidCallback? onChapterSettingsChanged;
  final TrainingMode trainingMode;
  final RepetitionMode repetitionMode;
  final ValueChanged<TrainingMode> onTrainingModeChanged;
  final ValueChanged<RepetitionMode> onRepetitionModeChanged;
  final bool? playingWhite;
  final VoidCallback? onChangePlayingSide;
  final ValueChanged<bool?>? onPlayingSideChanged;
  final bool? playingSideOverride;
  final Widget? chapterPreview;
  final VoidCallback? onOpenChapterSetup;
  final VoidCallback? onOpenAppSettings;
  final bool chaptersDeclined;

  const TrainingSettingsPanel({
    super.key,
    required this.settings,
    required this.saveSettings,
    required this.onQueueSettingsChanged,
    required this.onSettingsChanged,
    this.onChapterSettingsChanged,
    required this.trainingMode,
    required this.repetitionMode,
    required this.onTrainingModeChanged,
    required this.onRepetitionModeChanged,
    this.playingWhite,
    this.onChangePlayingSide,
    this.onPlayingSideChanged,
    this.playingSideOverride,
    this.chapterPreview,
    this.onOpenChapterSetup,
    this.onOpenAppSettings,
    this.chaptersDeclined = false,
  });

  @override
  State<TrainingSettingsPanel> createState() => _TrainingSettingsPanelState();
}

class _TrainingSettingsPanelState extends State<TrainingSettingsPanel> {
  TrainingSettings get settings => widget.settings;

  void _change(
    VoidCallback update, {
    bool queue = false,
    bool chapters = false,
  }) {
    if (!mounted) return;
    update();
    unawaited(widget.saveSettings());
    if (queue) widget.onQueueSettingsChanged();
    if (chapters) widget.onChapterSettingsChanged?.call();
    widget.onSettingsChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [..._session(), ..._learning(), ..._playback(), ..._material()],
  );

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
        subtitle: 'Maximum lines per session.',
        children: [
          _sessionLimit(
            'New lines',
            settings.newLinesPerSession,
            0,
            500,
            (n) => settings.newLinesPerSession = n,
          ),
          _sessionLimit(
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
          'Correct answers in a row',
          settings.correctStreakThreshold,
          1,
          10,
          (n) => settings.correctStreakThreshold = n,
          description: 'Consecutive correct answers needed for each move.',
        ),
        SettingsSwitchTile(
          label: 'Train the whole line',
          value: settings.trainingDepth == null,
          onChanged: (whole) =>
              _change(() => settings.trainingDepth = whole ? null : 10),
        ),
        if (settings.trainingDepth != null)
          SettingsValueRow(
            label: 'Train the first N moves',
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
                  if (n != null && n >= 1 && n <= 200) {
                    _change(() => settings.trainingDepth = n);
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
            control: widget.onPlayingSideChanged == null
                ? OutlinedButton(
                    onPressed: widget.onChangePlayingSide,
                    child: const Text('Change side…'),
                  )
                : SizedBox(
                    width: 180,
                    child: ChoiceField<String>(
                      value: widget.playingSideOverride == null
                          ? 'file'
                          : widget.playingSideOverride!
                          ? 'white'
                          : 'black',
                      items: const [
                        ChoiceItem(value: 'file', label: 'From file'),
                        ChoiceItem(value: 'white', label: 'White'),
                        ChoiceItem(value: 'black', label: 'Black'),
                      ],
                      onChanged: (value) => widget.onPlayingSideChanged!(
                        value == 'file' ? null : value == 'white',
                      ),
                    ),
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
                child: const Text('Preview chapter grouping'),
              ),
            ),
          ),
        if (widget.chapterPreview != null) widget.chapterPreview!,
      ],
    ),
  ];

  final Map<String, int> _lastLimits = {};
  Widget _sessionLimit(
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> update,
  ) => Column(
    children: [
      SettingsSwitchTile(
        label: 'Unlimited ${label.toLowerCase()}',
        value: value == 0,
        onChanged: (unlimited) => _change(() {
          if (unlimited) _lastLimits[label] = value;
          update(unlimited ? 0 : (_lastLimits[label] ?? 20));
        }),
      ),
      if (value > 0) _number(label, value, 1, max, update),
    ],
  );

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
