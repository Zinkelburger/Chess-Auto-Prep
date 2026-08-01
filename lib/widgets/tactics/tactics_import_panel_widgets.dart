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

/// A selectable row: tapping anywhere selects the mode. The active row gets a
/// primary-colored left border accent; the inactive row dims. (Andrew prefers
/// this fade look over radio buttons — don't "fix" it.)
class _FetchModeRow extends StatelessWidget {
  const _FetchModeRow({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: selected ? 1.0 : 0.40,
        duration: const Duration(milliseconds: 150),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          child: child,
        ),
      ),
    );
  }
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

  /// Expiry presets: days a puzzle stays trainable, or null for never.
  static const _agePresets = <(int?, String)>[
    (1, 'Today'),
    (2, '2 days'),
    (7, '7 days'),
    (14, '14 days'),
    (null, 'Never'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Expire puzzles after:',
          style: TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
        ),
        const Text(
          'How long a mined mistake stays in the queue. Separate from which '
          'games get fetched.',
          style: TextStyle(fontSize: 11, color: AppColors.onSurfaceMuted),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (days, label) in _agePresets)
              ChoiceChip(
                label: Text(label, style: const TextStyle(fontSize: 12)),
                selected: settings.maxAgeDays == days,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => onChanged(
                  days == null
                      ? settings.copyWith(clearMaxAgeDays: true)
                      : settings.copyWith(maxAgeDays: days),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(
              'Order:',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.onSurfaceSoft,
              ),
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
        Text(
          'Mistake types to include:',
          style: const TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
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
        Text(
          'Options:',
          style: const TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
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

// The import status banner and the resume-analysis banner used to live here.
// Both are gone: the review strip in the left pane is the one place a run is
// started, reported on and paused, and a second progress readout on the
// opposite side of the screen (with its own pause button, and a Dismiss that
// hid live progress) was the thing that made the page confusing.
