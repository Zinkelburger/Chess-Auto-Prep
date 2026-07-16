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

  /// Recency presets: days back, or null for all time.
  static const _agePresets = <(int?, String)>[
    (1, 'Today'),
    (2, '2 days'),
    (7, '7 days'),
    (14, '14 days'),
    (null, 'All time'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'From games in the last:',
          style: TextStyle(fontSize: 13, color: Colors.grey[300]),
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
              style: TextStyle(fontSize: 13, color: Colors.grey[300]),
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
        _MistakeTypeCheckbox(
          label: 'Group by game',
          selected: settings.groupByGame,
          onChanged: (v) => onChanged(settings.copyWith(groupByGame: v)),
        ),
        const SizedBox(height: 12),
        Text(
          'Mistake types to include:',
          style: TextStyle(fontSize: 13, color: Colors.grey[300]),
        ),
        _MistakeTypeCheckbox(
          label: 'Blunders (??)',
          selected: settings.mistakeTypes.contains('??'),
          onChanged: (v) => _toggleMistakeType('??', v),
        ),
        _MistakeTypeCheckbox(
          label: 'Mistakes (?)',
          selected: settings.mistakeTypes.contains('?'),
          onChanged: (v) => _toggleMistakeType('?', v),
        ),
        _MistakeTypeCheckbox(
          label: 'Inaccuracies (?!)',
          selected: settings.mistakeTypes.contains('?!'),
          onChanged: (v) => _toggleMistakeType('?!', v),
        ),
        if (showCustomType)
          _MistakeTypeCheckbox(
            label: 'Custom puzzles',
            selected: settings.mistakeTypes.contains(
              TacticsSessionSettings.customMistakeType,
            ),
            onChanged: (v) =>
                _toggleMistakeType(TacticsSessionSettings.customMistakeType, v),
          ),
        const SizedBox(height: 8),
        Text(
          'Options:',
          style: TextStyle(fontSize: 13, color: Colors.grey[300]),
        ),
        _MistakeTypeCheckbox(
          label: 'Unreviewed only',
          selected: settings.skipReviewed,
          onChanged: (v) => onChanged(settings.copyWith(skipReviewed: v)),
        ),
        _MistakeTypeCheckbox(
          label: 'Exclude 1-star rated',
          selected: !settings.includeOneStar,
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

class _MistakeTypeCheckbox extends StatelessWidget {
  const _MistakeTypeCheckbox({
    required this.label,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => onChanged(!selected),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: selected,
                onChanged: (v) => onChanged(v ?? false),
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Offer to finish analyzing games that were fetched but never analyzed
/// (a stopped or interrupted import). Sits at the top and mirrors
/// [TacticsImportStatusBanner]'s look, so stopping an import and resuming
/// it live in the same place: stop button while running, run button after.
class _ResumeAnalysisBanner extends StatelessWidget {
  const _ResumeAnalysisBanner({
    required this.pendingGameCount,
    required this.onResume,
  });

  final int pendingGameCount;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue),
      ),
      child: Row(
        children: [
          Icon(Icons.pause_circle_outline, size: 16, color: Colors.blue[300]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$pendingGameCount recent game${pendingGameCount == 1 ? '' : 's'} '
              'fetched but not analyzed yet',
            ),
          ),
          IconButton(
            icon: const Icon(Icons.play_circle_outlined, size: 20),
            tooltip: 'Resume analysis',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: onResume,
          ),
        ],
      ),
    );
  }
}

/// Progress/status banner shown during or after game import.
class TacticsImportStatusBanner extends StatelessWidget {
  const TacticsImportStatusBanner({
    super.key,
    required this.status,
    required this.isImporting,
    required this.hasActiveImport,
    required this.onCancelImport,
    required this.onDismiss,
  });

  final String status;
  final bool isImporting;
  final bool hasActiveImport;
  final VoidCallback onCancelImport;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isImporting)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (isImporting) const SizedBox(width: 12),
              if (!isImporting)
                Icon(
                  Icons.check_circle_outline,
                  size: 16,
                  color: Colors.green[400],
                ),
              if (!isImporting) const SizedBox(width: 8),
              Expanded(child: Text(status)),
              if (hasActiveImport)
                IconButton(
                  icon: const Icon(Icons.stop_circle_outlined, size: 20),
                  tooltip: 'Cancel analysis',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: onCancelImport,
                ),
              if (!isImporting)
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'Dismiss',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: onDismiss,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
