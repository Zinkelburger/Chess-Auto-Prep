import 'package:flutter/material.dart';

import '../../models/tactics_position.dart';
import '../../theme/app_colors.dart';
import '../common/list_search_field.dart';
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
    this.revision = 0,
    this.isLoading = false,
    this.selectedFen,
    required this.onSelectTactic,
    required this.onDeleteTactic,
    required this.onEditTactic,
    required this.onDeleteAll,
    this.onTrainMany,
    this.onSetRating,
    this.onBatchDelete,
  });

  final List<TacticsPosition> positions;

  /// The database's change counter. [positions] is mutated in place, so the
  /// list identity can't tell "same list, new contents" from "nothing
  /// changed" — this can, and it is what invalidates the memoized
  /// filter/sort below.
  final int revision;

  /// True while the database is still loading — shows a progress state
  /// instead of the misleading "no tactics yet" empty card.
  final bool isLoading;

  final String? selectedFen;

  /// Play this tactic. [visibleIndices] is the whole list as currently
  /// filtered/sorted, so Previous/Next during play can walk it in order.
  final void Function(int index, List<int> visibleIndices) onSelectTactic;
  final ValueChanged<int> onDeleteTactic;
  final ValueChanged<int> onEditTactic;

  /// Wipe the whole database (a destructive act, so the label says "delete",
  /// never "clear" — clearing sounds like resetting filters).
  final VoidCallback onDeleteAll;

  /// Start a scored training session over exactly these database indices, in
  /// the given order — the "Train these" button on the current filter result
  /// and the "Train" action on a multi-selection.
  final void Function(List<int> indices)? onTrainMany;

  final void Function(int index, int rating)? onSetRating;
  final void Function(List<int> indices)? onBatchDelete;

  @override
  State<TacticsBrowsePanel> createState() => _TacticsBrowsePanelState();
}

class _TacticsBrowsePanelState extends State<TacticsBrowsePanel> {
  // Mistake-type filters (all enabled by default).
  final Set<String> _enabledTypes = {'??', '?', '?!', 'custom'};
  TacticsStatusFilter _statusFilter = TacticsStatusFilter.all;
  TacticsBrowseSort _sort = TacticsBrowseSort.newest;
  int _minRating = 0; // 0 = show all ratings

  /// Flaw-tag filter: a tactic must carry EVERY selected tag (empty = all).
  final Set<String> _tagFilter = {};

  /// Free-text filter, applied alongside the chips in [_buildVisibleIndices]
  /// so the visible count in the bar already accounts for it.
  String _search = '';

  // Multi-select state.
  bool _selectMode = false;
  final Set<int> _selected = {};

  /// Memoized [_buildVisibleIndices] result. The whole control panel
  /// setStates on every session/import notification, and re-filtering and
  /// re-sorting the full database on each of those repaints was pure waste —
  /// the visible list only changes when the database does ([revision]) or a
  /// filter here does (each setter calls [_invalidateVisible]).
  List<int>? _visibleCache;
  int _cacheRevision = -1;
  List<TacticsPosition>? _cachePositions;

  void _invalidateVisible() => _visibleCache = null;

  List<int> get _visibleIndices {
    if (_visibleCache == null ||
        _cacheRevision != widget.revision ||
        !identical(_cachePositions, widget.positions)) {
      _visibleCache = _buildVisibleIndices();
      _cacheRevision = widget.revision;
      _cachePositions = widget.positions;
    }
    return _visibleCache!;
  }

  List<int> _buildVisibleIndices() {
    final positions = widget.positions;
    final indices = <int>[];
    for (int i = 0; i < positions.length; i++) {
      final pos = positions[i];
      if (!_enabledTypes.contains(pos.mistakeType)) continue;
      if (_minRating > 0 && pos.rating < _minRating) continue;
      if (_tagFilter.isNotEmpty && !_tagFilter.every(pos.flawTags.contains)) {
        continue;
      }
      // Only build the haystack when there is a needle — the concat per
      // position per pass showed up as pure garbage-churn with no search.
      if (_search.isNotEmpty &&
          !matchesSearch(
            _search,
            '${pos.gameWhite} ${pos.gameBlack} ${pos.gameDate} ${pos.userMove}',
          )) {
        continue;
      }
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
                'No tactics in this set yet.\n'
                'Run the engine analysis on the home screen to mine '
                'your games for puzzles.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final visibleIndices = _visibleIndices;

    return Column(
      children: [
        _BrowseFilterBar(
          totalCount: positions.length,
          visibleCount: visibleIndices.length,
          enabledTypes: _enabledTypes,
          statusFilter: _statusFilter,
          sort: _sort,
          minRating: _minRating,
          tagFilter: _tagFilter,
          selectMode: _selectMode,
          selectedCount: _selected.length,
          onToggleType: (type) => setState(() {
            _invalidateVisible();
            _enabledTypes.contains(type)
                ? _enabledTypes.remove(type)
                : _enabledTypes.add(type);
          }),
          onStatusChanged: (f) => setState(() {
            _invalidateVisible();
            _statusFilter = f;
          }),
          onSortChanged: (s) => setState(() {
            _invalidateVisible();
            _sort = s;
          }),
          onMinRatingChanged: (r) => setState(() {
            _invalidateVisible();
            _minRating = r;
          }),
          onToggleTag: (tag) => setState(() {
            _invalidateVisible();
            if (tag.isEmpty) {
              _tagFilter.clear();
            } else if (!_tagFilter.remove(tag)) {
              _tagFilter.add(tag);
            }
          }),
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
          onDeleteAll: widget.onDeleteAll,
          // Train what you see: the filtered/sorted list, or in select mode
          // the checked rows in the order the list shows them.
          onTrainVisible: widget.onTrainMany == null || visibleIndices.isEmpty
              ? null
              : () => widget.onTrainMany!(visibleIndices),
          onTrainSelected: widget.onTrainMany == null || _selected.isEmpty
              ? null
              : () {
                  final ordered = [
                    for (final i in visibleIndices)
                      if (_selected.contains(i)) i,
                  ];
                  _exitSelectMode();
                  widget.onTrainMany!(ordered);
                },
        ),
        const Divider(height: 1),
        // Under the chips, above the column header: the chips say *what kind*
        // of puzzle, this says *which game it came from*.
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: ListSearchField(
            hintText: 'Search by player, date or move',
            onChanged: (v) => setState(() {
              _invalidateVisible();
              _search = v;
            }),
          ),
        ),
        const Divider(height: 1),
        const TacticsBrowseHeader(),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: visibleIndices.length,
            // Fixed row height lets the list lay out without measuring every
            // child — noticeably snappier with board previews.
            itemExtent: 68,
            itemBuilder: (context, visIdx) {
              final realIndex = visibleIndices[visIdx];
              final pos = positions[realIndex];
              return TacticsBrowseRow(
                position: pos,
                index: realIndex,
                isSelected:
                    widget.selectedFen != null && widget.selectedFen == pos.fen,
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
