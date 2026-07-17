import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/tactics_position.dart';
import '../../theme/app_colors.dart';
import '../common/static_board_thumbnail.dart';
import 'puzzle_stats_display.dart';

part 'tactics_browse_row.dart';
part 'tactics_browse_filter_bar.dart';

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
    this.isLoading = false,
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

  /// True while the database is still loading — shows a progress state
  /// instead of the misleading "no tactics yet" empty card.
  final bool isLoading;

  final String? selectedFen;

  /// Play this tactic. [visibleIndices] is the whole list as currently
  /// filtered/sorted, so Previous/Next during play can walk it in order.
  final void Function(int index, List<int> visibleIndices) onSelectTactic;
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
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool(_showBoardsPrefKey, value),
    );
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
      if (widget.isLoading) {
        return const Center(child: CircularProgressIndicator());
      }
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
            // Fixed row height lets the list lay out without measuring every
            // child — noticeably snappier with board previews on.
            itemExtent: _showBoards ? 64 : 36,
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
                onTrain: () => widget.onSelectTactic(realIndex, visibleIndices),
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
