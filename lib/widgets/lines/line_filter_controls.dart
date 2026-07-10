import 'package:flutter/material.dart';

import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/coverage_helpers.dart';
import '../../utils/lines_filter_helpers.dart';

/// Header search/sort controls and coverage filter chips.
class LineFilterControls extends StatelessWidget {
  final TextEditingController searchController;
  final bool showOnlyMatchingPosition;
  final ValueChanged<bool> onShowOnlyMatchingPositionChanged;

  final VoidCallback? onCoveragePressed;
  final bool isCoverageRunning;

  final LineSortBy sortBy;
  final ValueChanged<LineSortBy> onSortByChanged;

  final LineMetricsFilter metricsFilter;
  final ValueChanged<LineMetricsFilter> onMetricsFilterChanged;

  final CoverageResult? coverageResult;
  final CoverageFilter coverageFilter;
  final ValueChanged<CoverageFilter> onCoverageFilterChanged;
  final Map<String, LineCoverageInfo> lineCoverage;
  final int totalLineCount;

  const LineFilterControls({
    super.key,
    required this.searchController,
    required this.showOnlyMatchingPosition,
    required this.onShowOnlyMatchingPositionChanged,
    this.onCoveragePressed,
    this.isCoverageRunning = false,
    required this.sortBy,
    required this.onSortByChanged,
    required this.metricsFilter,
    required this.onMetricsFilterChanged,
    this.coverageResult,
    required this.coverageFilter,
    required this.onCoverageFilterChanged,
    required this.lineCoverage,
    required this.totalLineCount,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HeaderSection(
          searchController: searchController,
          showOnlyMatchingPosition: showOnlyMatchingPosition,
          onShowOnlyMatchingPositionChanged: onShowOnlyMatchingPositionChanged,
          onCoveragePressed: onCoveragePressed,
          isCoverageRunning: isCoverageRunning,
          sortBy: sortBy,
          onSortByChanged: onSortByChanged,
          metricsFilter: metricsFilter,
          onMetricsFilterChanged: onMetricsFilterChanged,
        ),
        if (coverageResult != null)
          _CoverageFilterChips(
            coverageFilter: coverageFilter,
            onCoverageFilterChanged: onCoverageFilterChanged,
            lineCoverage: lineCoverage,
            totalLineCount: totalLineCount,
          ),
      ],
    );
  }
}

class _HeaderSection extends StatelessWidget {
  final TextEditingController searchController;
  final bool showOnlyMatchingPosition;
  final ValueChanged<bool> onShowOnlyMatchingPositionChanged;
  final VoidCallback? onCoveragePressed;
  final bool isCoverageRunning;
  final LineSortBy sortBy;
  final ValueChanged<LineSortBy> onSortByChanged;
  final LineMetricsFilter metricsFilter;
  final ValueChanged<LineMetricsFilter> onMetricsFilterChanged;

  const _HeaderSection({
    required this.searchController,
    required this.showOnlyMatchingPosition,
    required this.onShowOnlyMatchingPositionChanged,
    this.onCoveragePressed,
    this.isCoverageRunning = false,
    required this.sortBy,
    required this.onSortByChanged,
    required this.metricsFilter,
    required this.onMetricsFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Colors.grey[700]!, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wrap instead of Row: at narrow pane widths the controls flow onto
          // their own line rather than overflowing.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.library_books, size: 20, color: Colors.grey[400]),
                  const SizedBox(width: 8),
                  Text(
                    'Repertoire Lines',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[200],
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onCoveragePressed != null) ...[
                    FilledButton.icon(
                      onPressed: isCoverageRunning ? null : onCoveragePressed,
                      icon: isCoverageRunning
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.analytics_outlined, size: 16),
                      label: Text(
                        isCoverageRunning ? 'Analyzing...' : 'Coverage',
                        style: const TextStyle(fontSize: 12),
                      ),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  FilterChip(
                    label: const Text('Current Position'),
                    selected: showOnlyMatchingPosition,
                    onSelected: onShowOnlyMatchingPositionChanged,
                    labelStyle: const TextStyle(fontSize: 11),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: searchController,
            decoration: InputDecoration(
              hintText: 'Search name or moves ("1.e4 e5", "Sicilian")...',
              hintStyle: TextStyle(color: Colors.grey[500], fontSize: 12),
              prefixIcon: Icon(Icons.search, size: 18, color: Colors.grey[500]),
              suffixIcon: searchController.text.isNotEmpty
                  ? IconButton(
                      icon:
                          Icon(Icons.clear, size: 18, color: Colors.grey[500]),
                      onPressed: searchController.clear,
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.grey[700]!),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.grey[700]!),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.info),
              ),
              filled: true,
              fillColor: Colors.grey[850],
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              Text('Sort: ',
                  style: TextStyle(fontSize: 11, color: Colors.grey[400])),
              _SortChip(
                  label: 'Name',
                  value: LineSortBy.name,
                  sortBy: sortBy,
                  onChanged: onSortByChanged),
              _SortChip(
                  label: 'Quality',
                  value: LineSortBy.quality,
                  sortBy: sortBy,
                  onChanged: onSortByChanged),
              _SortChip(
                  label: 'Playability',
                  value: LineSortBy.playability,
                  sortBy: sortBy,
                  onChanged: onSortByChanged),
              _SortChip(
                  label: 'Traps',
                  value: LineSortBy.traps,
                  sortBy: sortBy,
                  onChanged: onSortByChanged),
              _SortChip(
                  label: 'Coherence',
                  value: LineSortBy.coherence,
                  sortBy: sortBy,
                  onChanged: onSortByChanged),
              _SortChip(
                  label: 'Length',
                  value: LineSortBy.length,
                  sortBy: sortBy,
                  onChanged: onSortByChanged),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              Text('Filter: ',
                  style: TextStyle(fontSize: 11, color: Colors.grey[400])),
              _MetricsFilterChip(
                  label: 'All',
                  value: LineMetricsFilter.all,
                  metricsFilter: metricsFilter,
                  onChanged: onMetricsFilterChanged),
              _MetricsFilterChip(
                  label: 'Hard moves',
                  value: LineMetricsFilter.hardMoves,
                  metricsFilter: metricsFilter,
                  onChanged: onMetricsFilterChanged),
              _MetricsFilterChip(
                  label: 'Trappy',
                  value: LineMetricsFilter.trappy,
                  metricsFilter: metricsFilter,
                  onChanged: onMetricsFilterChanged),
              _MetricsFilterChip(
                  label: 'Low coherence',
                  value: LineMetricsFilter.lowCoherence,
                  metricsFilter: metricsFilter,
                  onChanged: onMetricsFilterChanged),
            ],
          ),
        ],
      ),
    );
  }
}

class _SortChip extends StatelessWidget {
  final String label;
  final LineSortBy value;
  final LineSortBy sortBy;
  final ValueChanged<LineSortBy> onChanged;

  const _SortChip({
    required this.label,
    required this.value,
    required this.sortBy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = sortBy == value;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.info : Colors.grey[800],
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.white : Colors.grey[400],
          ),
        ),
      ),
    );
  }
}

class _MetricsFilterChip extends StatelessWidget {
  final String label;
  final LineMetricsFilter value;
  final LineMetricsFilter metricsFilter;
  final ValueChanged<LineMetricsFilter> onChanged;

  const _MetricsFilterChip({
    required this.label,
    required this.value,
    required this.metricsFilter,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = metricsFilter == value;
    return GestureDetector(
      onTap: () {
        if (isSelected && value != LineMetricsFilter.all) {
          onChanged(LineMetricsFilter.all);
        } else {
          onChanged(value);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.pgnMainLine : Colors.grey[800],
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.white : Colors.grey[400],
          ),
        ),
      ),
    );
  }
}

class _CoverageFilterChips extends StatelessWidget {
  final CoverageFilter coverageFilter;
  final ValueChanged<CoverageFilter> onCoverageFilterChanged;
  final Map<String, LineCoverageInfo> lineCoverage;
  final int totalLineCount;

  const _CoverageFilterChips({
    required this.coverageFilter,
    required this.onCoverageFilterChanged,
    required this.lineCoverage,
    required this.totalLineCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border(
          bottom: BorderSide(color: Colors.grey[800]!, width: 0.5),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _CoverageChip(
                label: 'All',
                filter: CoverageFilter.all,
                color: null,
                count: totalLineCount,
                selected: coverageFilter,
                onChanged: onCoverageFilterChanged),
            const SizedBox(width: 6),
            _CoverageChip(
                label: 'Covered',
                filter: CoverageFilter.covered,
                color: const Color(0xFF4CAF50),
                count: countCoveredLines(lineCoverage),
                selected: coverageFilter,
                onChanged: onCoverageFilterChanged),
            const SizedBox(width: 6),
            _CoverageChip(
                label: 'Too Shallow',
                filter: CoverageFilter.tooShallow,
                color: const Color(0xFFFFA726),
                count: countShallowLines(lineCoverage),
                selected: coverageFilter,
                onChanged: onCoverageFilterChanged),
            const SizedBox(width: 6),
            _CoverageChip(
                label: 'Too Deep',
                filter: CoverageFilter.tooDeep,
                color: const Color(0xFF42A5F5),
                count: countDeepLines(lineCoverage),
                selected: coverageFilter,
                onChanged: onCoverageFilterChanged),
            const SizedBox(width: 6),
            _CoverageChip(
                label: 'Unaccounted',
                filter: CoverageFilter.unaccounted,
                color: const Color(0xFFEF5350),
                count: countUnaccountedLines(lineCoverage),
                selected: coverageFilter,
                onChanged: onCoverageFilterChanged),
          ],
        ),
      ),
    );
  }
}

class _CoverageChip extends StatelessWidget {
  final String label;
  final CoverageFilter filter;
  final Color? color;
  final int count;
  final CoverageFilter selected;
  final ValueChanged<CoverageFilter> onChanged;

  const _CoverageChip({
    required this.label,
    required this.filter,
    required this.color,
    required this.count,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = selected == filter;
    return GestureDetector(
      onTap: () => onChanged(filter),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? (color ?? AppColors.info) : Colors.grey[800],
          borderRadius: BorderRadius.circular(12),
          border: color != null && !isSelected
              ? Border.all(color: color!.withValues(alpha: 0.4), width: 1)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? Colors.white : Colors.grey[400],
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.white.withValues(alpha: 0.25)
                    : Colors.grey[700],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? Colors.white : Colors.grey[400],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
