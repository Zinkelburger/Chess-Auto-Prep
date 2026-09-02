part of 'tactics_import_panel.dart';

/// Wraps [child] in a [Tooltip] only when [message] is non-null.
///
/// Avoid empty tooltip messages — Flutter's OverlayPortal-based tooltips can
/// assert if the message toggles between empty and non-empty during hover.
Widget _conditionalTooltip({required String? message, required Widget child}) {
  final text = message?.trim();
  if (text == null || text.isEmpty) return child;
  return Tooltip(message: text, child: child);
}

/// Session settings form (recency window, order, mistake-type filter,
/// 1-star toggle).
class _SessionSettingsForm extends StatelessWidget {
  const _SessionSettingsForm({
    required this.settings,
    required this.showCustomType,
    required this.onChanged,
  });

  final TacticsSessionSettings settings;

  /// Whether the database contains any custom puzzles; the checkbox is
  /// hidden otherwise so the dialog only offers choices that exist.
  final bool showCustomType;

  final ValueChanged<TacticsSessionSettings> onChanged;

  static const _orderLabels = {
    TacticsSessionOrder.newestFirst: 'Newest first',
    TacticsSessionOrder.leastReviewed: 'Least reviewed',
    TacticsSessionOrder.worstSuccessRate: 'Worst success rate',
    TacticsSessionOrder.random: 'Random',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _ExpiryField(
          days: settings.maxAgeDays,
          onChanged: (days) => onChanged(
            days == null
                ? settings.copyWith(clearMaxAgeDays: true)
                : settings.copyWith(maxAgeDays: days),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text(
              'Order:',
              style: TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
            ),
            const SizedBox(width: 8),
            DropdownButton<TacticsSessionOrder>(
              value: settings.order,
              isDense: true,
              underline: const SizedBox(),
              style: const TextStyle(fontSize: 13),
              items: [
                for (final entry in _orderLabels.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (v) {
                if (v != null) onChanged(settings.copyWith(order: v));
              },
            ),
          ],
        ),
        AppCheckbox(
          label: 'Group by game',
          value: settings.groupByGame,
          onChanged: (v) => onChanged(settings.copyWith(groupByGame: v)),
        ),
        const SizedBox(height: 12),
        const Text(
          'Mistake types to include:',
          style: TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
        ),
        AppCheckbox(
          label: 'Blunders (??)',
          value: settings.mistakeTypes.contains('??'),
          onChanged: (v) => _toggleMistakeType('??', v),
        ),
        AppCheckbox(
          label: 'Mistakes (?)',
          value: settings.mistakeTypes.contains('?'),
          onChanged: (v) => _toggleMistakeType('?', v),
        ),
        AppCheckbox(
          label: 'Inaccuracies (?!)',
          value: settings.mistakeTypes.contains('?!'),
          onChanged: (v) => _toggleMistakeType('?!', v),
        ),
        if (showCustomType)
          AppCheckbox(
            label: 'Custom puzzles',
            value: settings.mistakeTypes.contains(
              TacticsSessionSettings.customMistakeType,
            ),
            onChanged: (v) =>
                _toggleMistakeType(TacticsSessionSettings.customMistakeType, v),
          ),
        const SizedBox(height: 8),
        const Text(
          'Options:',
          style: TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
        ),
        AppCheckbox(
          label: 'Unreviewed only',
          value: settings.skipReviewed,
          onChanged: (v) => onChanged(settings.copyWith(skipReviewed: v)),
        ),
        AppCheckbox(
          label: 'Exclude 1-star rated',
          value: !settings.includeOneStar,
          onChanged: (v) => onChanged(settings.copyWith(includeOneStar: !v)),
        ),
      ],
    );
  }

  void _toggleMistakeType(String type, bool include) {
    final types = Set<String>.from(settings.mistakeTypes);
    if (include) {
      types.add(type);
    } else {
      types.remove(type);
    }
    onChanged(settings.copyWith(mistakeTypes: types));
  }
}

/// "Tactics expire after [ 14 ] days", as a sentence with a box in it.
///
/// This was five preset chips (Today / 2 / 7 / 14 / Never), which is both
/// less than the setting can do — any number of days is legal — and less
/// obvious: a row of chips reads as a filter someone already chose for you,
/// not as a number you own. A box you type into says the number is yours.
///
/// [days] is null for "never expire", which is the checkbox rather than a
/// magic value typed into the box. The last number typed is remembered while
/// the checkbox is on, so ticking it and changing your mind puts your window
/// back instead of the default.
class _ExpiryField extends StatefulWidget {
  const _ExpiryField({required this.days, required this.onChanged});

  final int? days;
  final ValueChanged<int?> onChanged;

  @override
  State<_ExpiryField> createState() => _ExpiryFieldState();
}

class _ExpiryFieldState extends State<_ExpiryField> {
  /// Ten years. Past this the window is "never" in everything but name, and
  /// the session filter has its own overflow guard well above it.
  static const int _maxDays = 3650;

  late final TextEditingController _controller = TextEditingController(
    text: '${widget.days ?? TacticsSessionSettings.defaultMaxAgeDays}',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_ExpiryField old) {
    super.didUpdateWidget(old);
    // Only follow the settings when they moved somewhere the box is not
    // already showing — otherwise every keystroke round-trips through the
    // parent and resets the cursor.
    final days = widget.days;
    if (days != null && days != int.tryParse(_controller.text.trim())) {
      _controller.text = '$days';
    }
  }

  void _onTyped(String raw) {
    final parsed = int.tryParse(raw.trim());
    // An empty or half-typed box changes nothing; the setting keeps the last
    // number that made sense until another one does.
    if (parsed == null || parsed < 1) return;
    widget.onChanged(parsed > _maxDays ? _maxDays : parsed);
  }

  @override
  Widget build(BuildContext context) {
    final never = widget.days == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Text(
              'Tactics expire after',
              style: TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 64,
              child: TextField(
                key: const Key('tactics-expiry-days-field'),
                controller: _controller,
                enabled: !never,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                ),
                onChanged: _onTyped,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'days',
              style: TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
            ),
          ],
        ),
        AppCheckbox(
          label: 'Never expire',
          value: never,
          onChanged: (v) => widget.onChanged(
            v
                ? null
                : (int.tryParse(_controller.text.trim()) ??
                      TacticsSessionSettings.defaultMaxAgeDays),
          ),
        ),
        const Text(
          'How long a mined mistake stays in the queue, counted from the day '
          'the game was played. Separate from which games get fetched.',
          style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
        ),
      ],
    );
  }
}

// The import status banner and the resume-analysis banner used to live here.
// Both are gone: the review strip in the left pane is the one place a run is
// started, reported on and paused, and a second progress readout on the
// opposite side of the screen (with its own pause button, and a Dismiss that
// hid live progress) was the thing that made the page confusing.
