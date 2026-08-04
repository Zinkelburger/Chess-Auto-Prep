part of 'tactics_browse_panel.dart';

class _BrowseFilterBar extends StatelessWidget {
  const _BrowseFilterBar({
    required this.totalCount,
    required this.visibleCount,
    required this.enabledTypes,
    required this.statusFilter,
    required this.sort,
    required this.minRating,
    required this.tagFilter,
    required this.onToggleTag,
    required this.selectMode,
    required this.selectedCount,
    required this.onToggleType,
    required this.onStatusChanged,
    required this.onSortChanged,
    required this.onMinRatingChanged,
    required this.onToggleSelectMode,
    required this.onDeleteSelected,
    required this.onSelectAll,
    required this.onDeleteAll,
    required this.onTrainVisible,
    required this.onTrainSelected,
  });

  final int totalCount;
  final int visibleCount;
  final Set<String> enabledTypes;
  final TacticsStatusFilter statusFilter;
  final TacticsBrowseSort sort;
  final int minRating;
  final Set<String> tagFilter;
  final ValueChanged<String> onToggleTag;
  final bool selectMode;
  final int selectedCount;
  final ValueChanged<String> onToggleType;
  final ValueChanged<TacticsStatusFilter> onStatusChanged;
  final ValueChanged<TacticsBrowseSort> onSortChanged;
  final ValueChanged<int> onMinRatingChanged;
  final VoidCallback onToggleSelectMode;
  final VoidCallback onDeleteSelected;
  final VoidCallback onSelectAll;
  final VoidCallback onDeleteAll;

  /// Train everything the current filters let through. Null disables.
  final VoidCallback? onTrainVisible;

  /// Train the checked rows (select mode). Null disables.
  final VoidCallback? onTrainSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top row: count, then the one thing browsing is *for* — training
          // what the filters matched — then selection and the delete-all.
          Row(
            children: [
              Text(
                '$visibleCount / $totalCount tactics',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 12),
              if (!selectMode)
                Tooltip(
                  message: visibleCount == 0
                      ? 'Nothing matches the current filters'
                      : 'Train these $visibleCount '
                            '${visibleCount == 1 ? 'puzzle' : 'puzzles'} in '
                            'the order shown — e.g. filter on Struggling, '
                            'then train what is left',
                  child: FilledButton.tonalIcon(
                    onPressed: onTrainVisible,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: Text(
                      'Train these ($visibleCount)',
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                  ),
                ),
              const Spacer(),
              if (selectMode) ...[
                Text(
                  '$selectedCount selected',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onSelectAll,
                  child: const Text('All', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: onTrainSelected,
                  icon: const Icon(Icons.play_arrow, size: 14),
                  label: const Text('Train', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: selectedCount > 0 ? onDeleteSelected : null,
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: AppColors.danger,
                  ),
                  label: const Text(
                    'Delete',
                    style: TextStyle(color: AppColors.danger, fontSize: 12),
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: onToggleSelectMode,
                  child: const Text('Cancel', style: TextStyle(fontSize: 12)),
                ),
              ] else ...[
                IconButton(
                  onPressed: onToggleSelectMode,
                  icon: const Icon(Icons.checklist, size: 18),
                  tooltip: 'Multi-select',
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
                // Muted, not red: this wipes the whole database, and painting
                // it the loudest colour on the bar begged the eye to press
                // it. The confirm dialog is where the danger colour lives.
                TextButton.icon(
                  onPressed: onDeleteAll,
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: AppColors.onSurfaceMuted,
                  ),
                  label: const Text(
                    'Delete all…',
                    style: TextStyle(
                      color: AppColors.onSurfaceMuted,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          // Filter row: mistake types + status + rating
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _MistakeTypeChip(
                type: '??',
                label: 'Blunders',
                color: AppColors.mistakeBlunder,
                enabled: enabledTypes.contains('??'),
                onToggle: () => onToggleType('??'),
              ),
              _MistakeTypeChip(
                type: '?',
                label: 'Mistakes',
                color: AppColors.mistakeMistake,
                enabled: enabledTypes.contains('?'),
                onToggle: () => onToggleType('?'),
              ),
              _MistakeTypeChip(
                type: '?!',
                label: 'Inaccuracies',
                color: AppColors.mistakeInaccuracy,
                enabled: enabledTypes.contains('?!'),
                onToggle: () => onToggleType('?!'),
              ),
              _MistakeTypeChip(
                type: '✎',
                label: 'Custom',
                color: AppColors.mistakeCustom,
                enabled: enabledTypes.contains('custom'),
                onToggle: () => onToggleType('custom'),
              ),
              const SizedBox(width: 8),
              ...TacticsStatusFilter.values.map(
                (f) => ChoiceChip(
                  label: Text(f.label, style: const TextStyle(fontSize: 11)),
                  selected: statusFilter == f,
                  onSelected: (_) => onStatusChanged(f),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 8),
              _MinRatingChip(
                minRating: minRating,
                onChanged: onMinRatingChanged,
              ),
              const SizedBox(width: 8),
              _FlawTagChip(selected: tagFilter, onToggle: onToggleTag),
            ],
          ),
          const SizedBox(height: 6),
          // Sort row
          Row(
            children: [
              const Icon(Icons.sort, size: 14, color: AppColors.onSurfaceMuted),
              const SizedBox(width: 4),
              ...TacticsBrowseSort.values.map(
                (s) => Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ChoiceChip(
                    label: Text(s.label, style: const TextStyle(fontSize: 11)),
                    selected: sort == s,
                    onSelected: (_) => onSortChanged(s),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MistakeTypeChip extends StatelessWidget {
  const _MistakeTypeChip({
    required this.type,
    required this.label,
    required this.color,
    required this.enabled,
    required this.onToggle,
  });

  final String type;
  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            type,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: color,
            ),
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
      selected: enabled,
      onSelected: (_) => onToggle(),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _FlawTagChip extends StatelessWidget {
  const _FlawTagChip({required this.selected, required this.onToggle});

  /// Every tag the flaw tagger can emit, grouped by family (impact,
  /// opportunity, phase, tempo).  Selecting several narrows with AND —
  /// "my low-clock endgame blunders".
  static const List<String> knownTags = [
    'reversed',
    'squandered',
    'miss',
    'lucky',
    'opening',
    'middlegame',
    'endgame',
    'low-clock',
    'hasty',
    'unrushed',
  ];

  final Set<String> selected;

  /// Called with a tag to toggle it, or '' for "Any tags" (clear all).
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Filter by flaw tags (all selected tags must match)',
      onSelected: onToggle,
      itemBuilder: (_) => [
        const PopupMenuItem(value: '', child: Text('Any tags')),
        for (final tag in knownTags)
          CheckedPopupMenuItem(
            value: tag,
            checked: selected.contains(tag),
            child: Text(tag),
          ),
      ],
      child: Chip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.label_outline,
              size: 13,
              color: selected.isNotEmpty
                  ? AppColors.starAccent
                  : AppColors.onSurfaceMuted,
            ),
            const SizedBox(width: 2),
            Text(
              selected.isEmpty ? 'Any tags' : selected.join(' + '),
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _MinRatingChip extends StatelessWidget {
  const _MinRatingChip({required this.minRating, required this.onChanged});

  final int minRating;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    // The chip and its menu say what the filter does in words. The old
    // "Any ★" / bare "3+" read as a cryptic glyph next to an equally cryptic
    // number — nobody could tell it meant "my own star ratings".
    return PopupMenuButton<int>(
      tooltip: 'Show only puzzles you rated at least this many stars',
      onSelected: onChanged,
      itemBuilder: (_) => [
        const PopupMenuItem(value: 0, child: Text('Any star rating')),
        for (int r = 2; r <= 5; r++)
          PopupMenuItem(
            value: r,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$r'),
                const Icon(Icons.star, size: 14, color: AppColors.starAccent),
                const Text(' and up'),
              ],
            ),
          ),
      ],
      child: Chip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.star,
              size: 13,
              color: minRating > 0
                  ? AppColors.starAccent
                  : AppColors.onSurfaceMuted,
            ),
            const SizedBox(width: 2),
            Text(
              minRating > 0 ? '$minRating★ and up' : 'Any star rating',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
