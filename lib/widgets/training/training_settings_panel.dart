import 'dart:async';
import '../../features/settings/models/settings_state.dart';
import '../../features/training/models/training_configuration.dart';
import '../../features/training/controllers/training_settings_controller.dart';
import 'package:flutter/material.dart';

import '../../features/training/models/training_settings.dart';
import '../../theme/app_text_styles.dart';
import '../settings/settings_widgets.dart';
import '../common/choice_field.dart';

/// Focused preference pages, using the same rows and cards as app settings.
class TrainingSettingsPanel extends StatefulWidget {
  final TrainingSettingsController configuration;
  final bool applyNextSitting;
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
    required this.configuration,
    this.applyNextSitting = false,
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
  late TrainingSettings settings;
  final _fieldControllers = <String, TextEditingController>{};
  final _fieldFocusNodes = <String, FocusNode>{};
  bool _disposing = false;

  Map<String, String> get _textValues => {
    'New lines': '${settings.newLinesPerSession}',
    'Reviews': '${settings.reviewsPerSession}',
    'Correct answers in a row': '${settings.correctStreakThreshold}',
    'Seconds before quiz': '${settings.learnDelaySec}',
    'training-depth': settings.trainingDepth?.toString() ?? '',
    'training-chapter-delimiter': settings.chapterDelimiter,
  };

  void _syncFields() {
    for (final entry in _textValues.entries) {
      final controller = _fieldControllers[entry.key];
      if (controller == null ||
          (_fieldFocusNodes[entry.key]?.hasFocus ?? false) ||
          controller.text == entry.value) {
        continue;
      }
      controller.value = TextEditingValue(
        text: entry.value,
        selection: TextSelection.collapsed(offset: entry.value.length),
      );
    }
  }

  TextEditingController _fieldController(String key, String value) =>
      _fieldControllers.putIfAbsent(
        key,
        () => TextEditingController(text: value),
      );

  FocusNode _fieldFocus(String key) => _fieldFocusNodes.putIfAbsent(key, () {
    final focus = FocusNode();
    focus.addListener(() {
      if (!_disposing && mounted && !focus.hasFocus) _syncFields();
    });
    return focus;
  });

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(TrainingSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.configuration, oldWidget.configuration)) {
      oldWidget.configuration.removeListener(_onSettingsChanged);
      _listen();
    }
  }

  void _listen() {
    _readSettings();
    widget.configuration.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    setState(_readSettings);
  }

  void _readSettings() {
    final state = widget.configuration.state;
    settings =
        (state.draft ?? state.committed)?.toSettings() ?? TrainingSettings();
    _syncFields();
  }

  @override
  void dispose() {
    _disposing = true;
    for (final controller in _fieldControllers.values) {
      controller.dispose();
    }
    for (final focus in _fieldFocusNodes.values) {
      focus.dispose();
    }
    widget.configuration.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _change(VoidCallback update) {
    if (!mounted) return;
    final before = TrainingConfiguration(settings);
    update();
    final changes = TrainingConfiguration(settings).changesFrom(before);
    unawaited(widget.configuration.edit(changes).catchError((Object _) {}));
    setState(() {});
  }

  Widget _status() {
    final state = widget.configuration.state;
    final label = switch (state.phase) {
      SettingsPhase.unloaded ||
      SettingsPhase.loading => 'Loading training settings…',
      SettingsPhase.saving => 'Saving training settings…',
      SettingsPhase.failed =>
        state.committed == null
            ? 'Training settings could not be loaded.'
            : 'Training settings could not be saved. Your changes are kept for retry.',
      SettingsPhase.ready =>
        widget.applyNextSitting
            ? 'Saved changes apply to your next sitting.'
            : 'Changes apply when you start training.',
    };
    return ListTile(
      title: Text(label),
      trailing: state.phase == SettingsPhase.failed
          ? TextButton(
              onPressed: () => unawaited(
                widget.configuration.retry().catchError((Object _) {}),
              ),
              child: const Text('Retry'),
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      _status(),
      ..._session(),
      ..._learning(),
      ..._playback(),
      ..._material(),
    ],
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
                controller: _fieldController(
                  'training-depth',
                  settings.trainingDepth?.toString() ?? '',
                ),
                focusNode: _fieldFocus('training-depth'),
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
            onChanged: (v) => _change(() => settings.reviewOrder = v),
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
            onChanged: (v) => _change(() => settings.chapterGrouping = v),
          ),
        if (!widget.chaptersDeclined &&
            settings.chapterGrouping == ChapterGroupingMode.namePrefix)
          SettingsValueRow(
            label: 'Name separator',
            description: 'For “Benoni #3”, use # to group under Benoni.',
            control: SizedBox(
              width: 100,
              child: TextFormField(
                controller: _fieldController(
                  'training-chapter-delimiter',
                  settings.chapterDelimiter,
                ),
                focusNode: _fieldFocus('training-chapter-delimiter'),
                maxLength: 3,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
                onChanged: (v) {
                  if (v.isNotEmpty) {
                    _change(() => settings.chapterDelimiter = v);
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
        controller: _fieldController(label, '$value'),
        focusNode: _fieldFocus(label),
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
