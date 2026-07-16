part of 'tactics_browse_panel.dart';

class _BrowseFilterBar extends StatelessWidget {
  const _BrowseFilterBar({
    required this.totalCount,
    required this.visibleCount,
    required this.enabledTypes,
    required this.statusFilter,
    required this.sort,
    required this.minRating,
    required this.showBoards,
    required this.onShowBoardsChanged,
    required this.selectMode,
    required this.selectedCount,
    required this.onToggleType,
    required this.onStatusChanged,
    required this.onSortChanged,
    required this.onMinRatingChanged,
    required this.onToggleSelectMode,
    required this.onDeleteSelected,
    required this.onSelectAll,
    required this.onClearAll,
    this.onCreatePuzzle,
  });

  final int totalCount;
  final int visibleCount;
  final Set<String> enabledTypes;
  final TacticsStatusFilter statusFilter;
  final TacticsBrowseSort sort;
  final int minRating;
  final bool showBoards;
  final ValueChanged<bool> onShowBoardsChanged;
  final bool selectMode;
  final int selectedCount;
  final ValueChanged<String> onToggleType;
  final ValueChanged<TacticsStatusFilter> onStatusChanged;
  final ValueChanged<TacticsBrowseSort> onSortChanged;
  final ValueChanged<int> onMinRatingChanged;
  final VoidCallback onToggleSelectMode;
  final VoidCallback onDeleteSelected;
  final VoidCallback onSelectAll;
  final VoidCallback onClearAll;
  final VoidCallback? onCreatePuzzle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top row: count + actions
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
              InkWell(
                onTap: () => onShowBoardsChanged(!showBoards),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: showBoards,
                        onChanged: (v) => onShowBoardsChanged(v ?? false),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'Show board previews',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
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
                  onPressed: selectedCount > 0 ? onDeleteSelected : null,
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: Colors.red,
                  ),
                  label: const Text(
                    'Delete',
                    style: TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: onToggleSelectMode,
                  child: const Text('Cancel', style: TextStyle(fontSize: 12)),
                ),
              ] else ...[
                if (onCreatePuzzle != null)
                  TextButton.icon(
                    onPressed: onCreatePuzzle,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text(
                      'New puzzle',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                IconButton(
                  onPressed: onToggleSelectMode,
                  icon: const Icon(Icons.checklist, size: 18),
                  tooltip: 'Multi-select',
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: onClearAll,
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: Colors.red,
                  ),
                  label: const Text(
                    'Clear All',
                    style: TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          // Filter row: mistake types + status + rating
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _MistakeTypeChip(
                type: '??',
                label: 'Blunders',
                color: Colors.red,
                enabled: enabledTypes.contains('??'),
                onToggle: () => onToggleType('??'),
              ),
              _MistakeTypeChip(
                type: '?',
                label: 'Mistakes',
                color: Colors.orange,
                enabled: enabledTypes.contains('?'),
                onToggle: () => onToggleType('?'),
              ),
              _MistakeTypeChip(
                type: '?!',
                label: 'Inaccuracies',
                color: Colors.yellow.shade700,
                enabled: enabledTypes.contains('?!'),
                onToggle: () => onToggleType('?!'),
              ),
              _MistakeTypeChip(
                type: '✎',
                label: 'Custom',
                color: Colors.lightBlue,
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
            ],
          ),
          const SizedBox(height: 4),
          // Sort row
          Row(
            children: [
              const Icon(Icons.sort, size: 14, color: Colors.grey),
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

class _MinRatingChip extends StatelessWidget {
  const _MinRatingChip({required this.minRating, required this.onChanged});

  final int minRating;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Minimum star rating',
      onSelected: onChanged,
      itemBuilder: (_) => [
        const PopupMenuItem(value: 0, child: Text('Any rating')),
        for (int r = 2; r <= 5; r++)
          PopupMenuItem(
            value: r,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$r'),
                const Icon(Icons.star, size: 14, color: Colors.amber),
                const Text('+'),
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
              color: minRating > 0 ? Colors.amber : Colors.grey,
            ),
            const SizedBox(width: 2),
            Text(
              minRating > 0 ? '$minRating+' : 'Any',
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
