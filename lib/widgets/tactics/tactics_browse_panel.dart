import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/tactics_position.dart';
import '../chess_board_widget.dart';
import 'puzzle_stats_display.dart';

/// How positions are sorted in the browse list.
enum TacticsBrowseSort {
  newest('Newest first'),
  oldest('Oldest first'),
  worstSuccess('Worst success'),
  leastReviewed('Least reviewed');

  const TacticsBrowseSort(this.label);
  final String label;
}

/// Review-status filter for the browse list.
enum TacticsStatusFilter {
  all('All'),
  newOnly('New'),
  struggling('Struggling');

  const TacticsStatusFilter(this.label);
  final String label;
}

/// Scrollable list of stored tactics for review and selection.
class TacticsBrowsePanel extends StatefulWidget {
  const TacticsBrowsePanel({
    super.key,
    required this.positions,
    this.selectedFen,
    required this.onSelectTactic,
    required this.onDeleteTactic,
    required this.onEditTactic,
    required this.onClearAll,
    this.onSetRating,
    this.onBatchDelete,
    this.onCreatePuzzle,
  });

  final List<TacticsPosition> positions;
  final String? selectedFen;
  final ValueChanged<int> onSelectTactic;
  final ValueChanged<int> onDeleteTactic;
  final ValueChanged<int> onEditTactic;
  final VoidCallback onClearAll;
  final void Function(int index, int rating)? onSetRating;
  final void Function(List<int> indices)? onBatchDelete;

  /// Opens the manual puzzle creator.  Hidden when null.
  final VoidCallback? onCreatePuzzle;

  @override
  State<TacticsBrowsePanel> createState() => _TacticsBrowsePanelState();
}

class _TacticsBrowsePanelState extends State<TacticsBrowsePanel> {
  static const String _showBoardsPrefKey = 'tactics_browse_show_boards';

  // Mistake-type filters (all enabled by default).
  final Set<String> _enabledTypes = {'??', '?', '?!', 'custom'};
  TacticsStatusFilter _statusFilter = TacticsStatusFilter.all;
  TacticsBrowseSort _sort = TacticsBrowseSort.newest;
  int _minRating = 0; // 0 = show all ratings

  /// Show a small board preview next to each tactic.
  bool _showBoards = true;

  // Multi-select state.
  bool _selectMode = false;
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      final saved = prefs.getBool(_showBoardsPrefKey);
      if (saved != null && saved != _showBoards) {
        setState(() => _showBoards = saved);
      }
    });
  }

  void _setShowBoards(bool value) {
    setState(() => _showBoards = value);
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setBool(_showBoardsPrefKey, value));
  }

  List<int> _buildVisibleIndices() {
    final positions = widget.positions;
    final indices = <int>[];
    for (int i = 0; i < positions.length; i++) {
      final pos = positions[i];
      if (!_enabledTypes.contains(pos.mistakeType)) continue;
      if (_minRating > 0 && pos.rating < _minRating) continue;
      switch (_statusFilter) {
        case TacticsStatusFilter.all:
          break;
        case TacticsStatusFilter.newOnly:
          if (pos.reviewCount > 0) continue;
        case TacticsStatusFilter.struggling:
          if (pos.reviewCount == 0 || pos.successRate >= 0.5) continue;
      }
      indices.add(i);
    }
    // Apply sort.
    switch (_sort) {
      case TacticsBrowseSort.newest:
        break; // File order is newest-last; reverse for newest-first display.
      case TacticsBrowseSort.oldest:
        // File order is already oldest-first; keep as-is.
        return indices;
      case TacticsBrowseSort.worstSuccess:
        indices.sort((a, b) {
          final sa = positions[a].successRate;
          final sb = positions[b].successRate;
          return sa.compareTo(sb);
        });
        return indices;
      case TacticsBrowseSort.leastReviewed:
        indices.sort((a, b) {
          return positions[a].reviewCount.compareTo(positions[b].reviewCount);
        });
        return indices;
    }
    return indices.reversed.toList();
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final positions = widget.positions;

    if (positions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'No tactics in this set yet.\nImport games to discover tactical positions, or create your own.',
                textAlign: TextAlign.center,
              ),
              if (widget.onCreatePuzzle != null) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('New puzzle'),
                  onPressed: widget.onCreatePuzzle,
                ),
              ],
            ],
          ),
        ),
      );
    }

    final visibleIndices = _buildVisibleIndices();

    return Column(
      children: [
        _BrowseFilterBar(
          totalCount: positions.length,
          visibleCount: visibleIndices.length,
          enabledTypes: _enabledTypes,
          statusFilter: _statusFilter,
          sort: _sort,
          minRating: _minRating,
          showBoards: _showBoards,
          onShowBoardsChanged: _setShowBoards,
          selectMode: _selectMode,
          selectedCount: _selected.length,
          onToggleType: (type) => setState(() {
            _enabledTypes.contains(type)
                ? _enabledTypes.remove(type)
                : _enabledTypes.add(type);
          }),
          onStatusChanged: (f) => setState(() => _statusFilter = f),
          onSortChanged: (s) => setState(() => _sort = s),
          onMinRatingChanged: (r) => setState(() => _minRating = r),
          onToggleSelectMode: () {
            if (_selectMode) {
              _exitSelectMode();
            } else {
              setState(() => _selectMode = true);
            }
          },
          onDeleteSelected: () {
            if (_selected.isEmpty) return;
            final sorted = _selected.toList()..sort((a, b) => b.compareTo(a));
            if (widget.onBatchDelete != null) {
              widget.onBatchDelete!(sorted);
            } else {
              for (final idx in sorted) {
                widget.onDeleteTactic(idx);
              }
            }
            _exitSelectMode();
          },
          onSelectAll: () {
            setState(() => _selected.addAll(visibleIndices));
          },
          onClearAll: widget.onClearAll,
          onCreatePuzzle: widget.onCreatePuzzle,
        ),
        const Divider(height: 1),
        TacticsBrowseHeader(showBoards: _showBoards),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: visibleIndices.length,
            itemBuilder: (context, visIdx) {
              final realIndex = visibleIndices[visIdx];
              final pos = positions[realIndex];
              return TacticsBrowseRow(
                position: pos,
                index: realIndex,
                isSelected:
                    widget.selectedFen != null && widget.selectedFen == pos.fen,
                showBoard: _showBoards,
                // Plain click edits; the play button loads it for training.
                onTap: _selectMode
                    ? () => setState(() {
                          _selected.contains(realIndex)
                              ? _selected.remove(realIndex)
                              : _selected.add(realIndex);
                        })
                    : () => widget.onEditTactic(realIndex),
                onTrain: () => widget.onSelectTactic(realIndex),
                onDelete: () => widget.onDeleteTactic(realIndex),
                onEdit: () => widget.onEditTactic(realIndex),
                onSetRating: widget.onSetRating != null
                    ? (rating) => widget.onSetRating!(realIndex, rating)
                    : null,
                selectMode: _selectMode,
                checked: _selected.contains(realIndex),
              );
            },
          ),
        ),
      ],
    );
  }
}

class TacticsBrowseHeader extends StatelessWidget {
  const TacticsBrowseHeader({super.key, this.showBoards = false});

  /// Match the leading space of the rows (board preview + action buttons).
  final bool showBoards;

  static const _headerStyle = TextStyle(
    fontWeight: FontWeight.bold,
    fontSize: 12,
    color: Colors.grey,
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          SizedBox(width: showBoards ? 168 : 100),
          const SizedBox(width: 32, child: Text('Type', style: _headerStyle)),
          const SizedBox(width: 8),
          const SizedBox(width: 80, child: Text('Rating', style: _headerStyle)),
          const SizedBox(width: 8),
          const Expanded(flex: 3, child: Text('Game', style: _headerStyle)),
          const SizedBox(width: 8),
          const Expanded(flex: 2, child: Text('Context', style: _headerStyle)),
          const SizedBox(width: 8),
          const Expanded(
              flex: 2, child: Text('Played → Best', style: _headerStyle)),
          const SizedBox(width: 8),
          const SizedBox(
              width: 60,
              child: Text('Stats',
                  style: _headerStyle, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

class TacticsBrowseRow extends StatelessWidget {
  const TacticsBrowseRow({
    super.key,
    required this.position,
    required this.index,
    required this.isSelected,
    required this.onTap,
    this.onTrain,
    required this.onDelete,
    required this.onEdit,
    this.onSetRating,
    this.selectMode = false,
    this.checked = false,
    this.showBoard = false,
  });

  final TacticsPosition position;
  final int index;
  final bool isSelected;
  final VoidCallback onTap;

  /// Loads this tactic onto the board for training. Hidden when null.
  final VoidCallback? onTrain;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final ValueChanged<int>? onSetRating;
  final bool selectMode;
  final bool checked;

  /// Show a small board preview of the position.
  final bool showBoard;

  @override
  Widget build(BuildContext context) {
    final pos = position;

    final isDimmed = pos.rating == 1;

    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: isDimmed ? 0.45 : 1.0,
        child: Container(
          decoration: BoxDecoration(
            color: isSelected || checked
                ? Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.3)
                : (index.isEven
                    ? Colors.transparent
                    : Colors.white.withValues(alpha: 0.02)),
            border: Border(
              bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              if (showBoard) ...[
                _BoardThumbnail(fen: position.fen),
                const SizedBox(width: 8),
              ],
              if (selectMode)
                Checkbox(
                  value: checked,
                  onChanged: (_) => onTap(),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                )
              else ...[
                if (onTrain != null)
                  IconButton(
                    onPressed: onTrain,
                    icon: const Icon(Icons.play_arrow,
                        size: 18, color: Colors.green),
                    tooltip: 'Train this tactic',
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                    padding: EdgeInsets.zero,
                  ),
                IconButton(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit, size: 16),
                  tooltip: 'Edit tactic',
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
                IconButton(
                  onPressed: onDelete,
                  icon: Icon(Icons.close,
                      size: 16, color: Colors.red.withValues(alpha: 0.6)),
                  tooltip: 'Delete tactic',
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
              ],
              const SizedBox(width: 4),
              SizedBox(
                width: 32,
                child: Text(
                  pos.mistakeType == 'custom' ? '✎' : pos.mistakeType,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: switch (pos.mistakeType) {
                      '??' => Colors.red,
                      '?!' => Colors.yellow,
                      'custom' => Colors.lightBlue,
                      _ => Colors.orange,
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 80,
                child: _BrowseStarRating(
                  rating: pos.rating,
                  onSetRating: onSetRating,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: Text(
                  '${pos.gameWhite} vs ${pos.gameBlack}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: Text(
                  pos.positionContext,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: Text(
                  '${pos.userMove} → ${pos.bestMove}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(width: 8),
              PuzzleStatsDisplay(position: pos),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small static board preview for a browse row, oriented so the side to move
/// is at the bottom (same perspective as training).
class _BoardThumbnail extends StatelessWidget {
  const _BoardThumbnail({required this.fen});

  final String fen;

  static const double _size = 60;

  @override
  Widget build(BuildContext context) {
    final Position position;
    try {
      position = Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      return const SizedBox(
        width: _size,
        height: _size,
        child: Icon(Icons.broken_image_outlined, size: 20, color: Colors.grey),
      );
    }
    return SizedBox(
      width: _size,
      height: _size,
      child: IgnorePointer(
        child: ChessBoardWidget(
          position: position,
          flipped: position.turn == Side.black,
          enableUserMoves: false,
        ),
      ),
    );
  }
}

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
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
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
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Text('Show board previews',
                        style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              const Spacer(),
              if (selectMode) ...[
                Text('$selectedCount selected',
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onSelectAll,
                  child: const Text('All', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: selectedCount > 0 ? onDeleteSelected : null,
                  icon: const Icon(Icons.delete_outline,
                      size: 14, color: Colors.red),
                  label: const Text('Delete',
                      style: TextStyle(color: Colors.red, fontSize: 12)),
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
                    label: const Text('New puzzle',
                        style: TextStyle(fontSize: 12)),
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
                  icon: const Icon(Icons.delete_outline,
                      size: 14, color: Colors.red),
                  label: const Text('Clear All',
                      style: TextStyle(color: Colors.red, fontSize: 12)),
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
              ...TacticsStatusFilter.values.map((f) => ChoiceChip(
                    label: Text(f.label, style: const TextStyle(fontSize: 11)),
                    selected: statusFilter == f,
                    onSelected: (_) => onStatusChanged(f),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  )),
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
              ...TacticsBrowseSort.values.map((s) => Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text(s.label, style: const TextStyle(fontSize: 11)),
                      selected: sort == s,
                      onSelected: (_) => onSortChanged(s),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  )),
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
          Text(type,
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 12, color: color)),
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
            Icon(Icons.star, size: 13,
                color: minRating > 0 ? Colors.amber : Colors.grey),
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

class _BrowseStarRating extends StatelessWidget {
  const _BrowseStarRating({required this.rating, this.onSetRating});

  final int rating;
  final ValueChanged<int>? onSetRating;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final star = i + 1;
        return GestureDetector(
          onTap: onSetRating != null
              ? () => onSetRating!(rating == star ? 0 : star)
              : null,
          child: Icon(
            star <= rating ? Icons.star : Icons.star_border,
            size: 14,
            color: star <= rating ? Colors.amber : Colors.grey[700],
          ),
        );
      }),
    );
  }
}
