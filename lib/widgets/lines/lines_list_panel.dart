import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../models/repertoire_line.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import '../../theme/app_colors.dart';
import '../../utils/coverage_helpers.dart';
import 'package:chess_auto_prep/services/line_metrics_helpers.dart';
import '../../utils/lines_filter_helpers.dart';
import '../layout/empty_state_placeholder.dart';
import 'line_item_row.dart';
import 'line_table_layout.dart';

/// Flat, sortable table of repertoire lines: a header row of clickable
/// stat columns above the scrolling list.
class LinesListPanel extends StatelessWidget {
  final ScrollController scrollController;
  final List<RepertoireLine> filteredLines;
  final LineTableLayout layout;
  final LineSortBy sortBy;
  final bool sortAscending;
  final ValueChanged<LineSortBy> onSortChanged;
  final List<String> currentMoveSequence;
  final bool showCoverage;
  final Map<String, LineCoverageInfo> lineCoverage;
  final Map<String, LineQualityInfo> lineMetrics;
  final Map<String, LineDisplayData> displayIndex;
  final void Function(RepertoireLine line)? onLineSelected;
  final void Function(RepertoireLine line, String newTitle)? onLineRenamed;
  final void Function(RepertoireLine line)? onLineDeleted;
  final void Function(List<String> moveSequence)? onNavigateToPosition;
  final NavigationStack? navigationStack;
  final BoardPreviewController? boardPreview;
  final bool hasActiveFilters;
  final VoidCallback onResetFilters;

  /// True when a coverage status filter is selected but no analysis exists;
  /// the list then prompts for a run instead of showing an empty result.
  final bool needsCoverageRun;
  final bool isCoverageRunning;
  final VoidCallback? onRunCoverage;

  const LinesListPanel({
    super.key,
    required this.scrollController,
    required this.filteredLines,
    required this.layout,
    required this.sortBy,
    required this.sortAscending,
    required this.onSortChanged,
    this.currentMoveSequence = const [],
    this.showCoverage = false,
    required this.lineCoverage,
    required this.lineMetrics,
    this.displayIndex = const {},
    this.onLineSelected,
    this.onLineRenamed,
    this.onLineDeleted,
    this.onNavigateToPosition,
    this.navigationStack,
    this.boardPreview,
    required this.hasActiveFilters,
    required this.onResetFilters,
    this.needsCoverageRun = false,
    this.isCoverageRunning = false,
    this.onRunCoverage,
  });

  @override
  Widget build(BuildContext context) {
    if (needsCoverageRun) {
      return _CoverageRunPrompt(
        isCoverageRunning: isCoverageRunning,
        onRunCoverage: onRunCoverage,
        onResetFilters: onResetFilters,
      );
    }

    if (filteredLines.isEmpty) {
      return EmptyStatePlaceholder(
        icon: Icons.search_off,
        iconSize: 48,
        title: hasActiveFilters
            ? 'No lines match the current filters'
            : 'No lines in repertoire',
        trailing: hasActiveFilters
            ? TextButton(
                onPressed: onResetFilters,
                child: const Text('Show all lines'),
              )
            : null,
      );
    }

    return Column(
      children: [
        _TableHeader(
          layout: layout,
          sortBy: sortBy,
          sortAscending: sortAscending,
          onSortChanged: onSortChanged,
        ),
        Expanded(
          child: ListView.builder(
            controller: scrollController,
            itemCount: filteredLines.length,
            itemBuilder: (context, index) {
              final line = filteredLines[index];
              return LineItemRow(
                line: line,
                index: index,
                layout: layout,
                currentMoveSequence: currentMoveSequence,
                showCoverage: showCoverage,
                coverageInfo: lineCoverage[line.id],
                metrics: lineMetrics[line.id],
                displayTitle: displayIndex[line.id]?.title,
                onLineSelected: onLineSelected,
                onLineRenamed: onLineRenamed,
                onLineDeleted: onLineDeleted,
                onNavigateToPosition: onNavigateToPosition,
                navigationStack: navigationStack,
                boardPreview: boardPreview,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Column headers; click to sort, click again to reverse.
class _TableHeader extends StatelessWidget {
  final LineTableLayout layout;
  final LineSortBy sortBy;
  final bool sortAscending;
  final ValueChanged<LineSortBy> onSortChanged;

  const _TableHeader({
    required this.layout,
    required this.sortBy,
    required this.sortAscending,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: AppColors.surfaceInset,
        border: Border(bottom: BorderSide(color: AppColors.outline, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _HeaderCell(
                label: 'Line',
                sort: LineSortBy.name,
                active: sortBy == LineSortBy.name,
                ascending: sortAscending,
                onTap: onSortChanged,
              ),
            ),
          ),
          if (layout.showMovesColumn)
            _fixedCell(LineTableLayout.movesWidth, 'Moves', LineSortBy.moves),
          _fixedCell(LineTableLayout.easeWidth, 'Ease', LineSortBy.ease),
          _fixedCell(
            LineTableLayout.coherenceWidth,
            'Coherence',
            LineSortBy.coherence,
          ),
          if (layout.showTrapsColumn)
            _fixedCell(LineTableLayout.trapsWidth, 'Traps', LineSortBy.traps),
          if (layout.showCoverageColumn)
            _fixedCell(
              LineTableLayout.coverageWidth,
              'Coverage',
              LineSortBy.coverage,
            ),
        ],
      ),
    );
  }

  Widget _fixedCell(double width, String label, LineSortBy sort) {
    return SizedBox(
      width: width,
      child: Center(
        child: _HeaderCell(
          label: label,
          sort: sort,
          active: sortBy == sort,
          ascending: sortAscending,
          onTap: onSortChanged,
        ),
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String label;
  final LineSortBy sort;
  final bool active;
  final bool ascending;
  final ValueChanged<LineSortBy> onTap;

  const _HeaderCell({
    required this.label,
    required this.sort,
    required this.active,
    required this.ascending,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onTap(sort),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                  color: active ? AppColors.ink : AppColors.onSurfaceSoft,
                ),
              ),
            ),
            if (active)
              Icon(
                ascending ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                size: 16,
                color: AppColors.ink,
              ),
          ],
        ),
      ),
    );
  }
}

/// Shown when a coverage status filter is active but coverage was never run.
class _CoverageRunPrompt extends StatelessWidget {
  final bool isCoverageRunning;
  final VoidCallback? onRunCoverage;
  final VoidCallback onResetFilters;

  const _CoverageRunPrompt({
    required this.isCoverageRunning,
    required this.onRunCoverage,
    required this.onResetFilters,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.analytics_outlined,
            size: 48,
            color: AppColors.onSurfaceDim,
          ),
          const SizedBox(height: 12),
          Text(
            isCoverageRunning
                ? 'Coverage analysis is running…'
                : 'Coverage has not been analyzed yet',
            style: const TextStyle(
              color: AppColors.onSurfaceSoft,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            isCoverageRunning
                ? 'Results will appear here when the run finishes.'
                : 'Run a coverage analysis to see which lines are covered.',
            style: const TextStyle(
              color: AppColors.onSurfaceMuted,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 16),
          if (!isCoverageRunning && onRunCoverage != null)
            FilledButton.icon(
              onPressed: onRunCoverage,
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('Run coverage analysis'),
            ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onResetFilters,
            child: const Text('Show all lines'),
          ),
        ],
      ),
    );
  }
}
