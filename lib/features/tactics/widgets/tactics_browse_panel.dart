import 'package:flutter/material.dart';

import '../models/tactics_position.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/common/list_search_field.dart';
import '../../../widgets/common/static_board_thumbnail.dart';
import 'puzzle_stats_display.dart';
import 'tactics_browse_filter.dart';

part 'tactics_browse_row.dart';
part 'tactics_browse_filter_bar.dart';

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
  /// The chips, the sort and the search box, as one value (see
  /// [TacticsBrowseFilter]) — it also *is* the predicate the list is built
  /// with, so the bar and the visible rows cannot disagree.
  TacticsBrowseFilter _filter = const TacticsBrowseFilter();

  // Multi-select state.
  bool _selectMode = false;
  final Set<int> _selected = {};

  /// Memoized [TacticsBrowseFilter.apply] result. The whole control panel
  /// setStates on every session/import notification, and re-filtering and
  /// re-sorting the full database on each of those repaints was pure waste —
  /// the visible list only changes when the database does ([revision]) or the
  /// filter does (every change goes through [_setFilter]).
  List<int>? _visibleCache;
  int _cacheRevision = -1;
  List<TacticsPosition>? _cachePositions;

  void _invalidateVisible() => _visibleCache = null;

  void _setFilter(TacticsBrowseFilter filter) => setState(() {
    _invalidateVisible();
    _filter = filter;
  });

  List<int> get _visibleIndices {
    if (_visibleCache == null ||
        _cacheRevision != widget.revision ||
        !identical(_cachePositions, widget.positions)) {
      _visibleCache = _filter.apply(widget.positions);
      _cacheRevision = widget.revision;
      _cachePositions = widget.positions;
    }
    return _visibleCache!;
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
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
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
          filter: _filter,
          onFilterChanged: _setFilter,
          selectMode: _selectMode,
          selectedCount: _selected.length,
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
            onChanged: (v) => _setFilter(_filter.copyWith(search: v)),
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
