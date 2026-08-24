import 'package:flutter/material.dart';

import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/coverage_helpers.dart';
import '../../utils/lines_filter_helpers.dart';

/// Search box plus flat rows of toggle chips. Every control here is a real
/// toggle: click it and it becomes checked, click again and it unchecks.
/// Nothing opens a nested menu.
class LineFilterControls extends StatelessWidget {
  final TextEditingController searchController;
  final bool showOnlyMatchingPosition;
  final ValueChanged<bool> onShowOnlyMatchingPositionChanged;

  final Set<LineMetricsFilter> metricsFilters;
  final void Function(LineMetricsFilter filter, bool active)
  onMetricsFilterToggled;

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
    required this.metricsFilters,
    required this.onMetricsFilterToggled,
    this.coverageResult,
    required this.coverageFilter,
    required this.onCoverageFilterChanged,
    required this.lineCoverage,
    required this.totalLineCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: const Border(
          bottom: BorderSide(color: AppColors.outline, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSearchField(),
          const SizedBox(height: 8),
          // Wrap, not Row: the browser must survive narrow side-panel widths
          // without overflowing.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _toggleChip(
                label: 'Current position',
                selected: showOnlyMatchingPosition,
                onSelected: onShowOnlyMatchingPositionChanged,
              ),
              _toggleChip(
                label: 'Hard moves',
                selected: metricsFilters.contains(LineMetricsFilter.hardMoves),
                onSelected: (v) =>
                    onMetricsFilterToggled(LineMetricsFilter.hardMoves, v),
              ),
              _toggleChip(
                label: 'Has traps',
                selected: metricsFilters.contains(LineMetricsFilter.trappy),
                onSelected: (v) =>
                    onMetricsFilterToggled(LineMetricsFilter.trappy, v),
              ),
              _toggleChip(
                label: 'Low coherence',
                selected: metricsFilters.contains(
                  LineMetricsFilter.lowCoherence,
                ),
                onSelected: (v) =>
                    onMetricsFilterToggled(LineMetricsFilter.lowCoherence, v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _CoverageFilterRow(
            coverageFilter: coverageFilter,
            onCoverageFilterChanged: onCoverageFilterChanged,
            lineCoverage: lineCoverage,
            totalLineCount: totalLineCount,
            hasCoverageResult: coverageResult != null,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return TextField(
      controller: searchController,
      decoration: InputDecoration(
        hintText: 'Search by name or moves...',
        hintStyle: const TextStyle(
          color: AppColors.onSurfaceMuted,
          fontSize: 12,
        ),
        prefixIcon: const Icon(
          Icons.search,
          size: 16,
          color: AppColors.onSurfaceMuted,
        ),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 28,
          maxHeight: 32,
        ),
        suffixIcon: searchController.text.isNotEmpty
            ? IconButton(
                icon: const Icon(
                  Icons.clear,
                  size: 14,
                  color: AppColors.onSurfaceMuted,
                ),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: searchController.clear,
              )
            : null,
        suffixIconConstraints: const BoxConstraints(
          minWidth: 28,
          minHeight: 28,
          maxHeight: 32,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.info),
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  Widget _toggleChip({
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
      labelStyle: const TextStyle(fontSize: 11),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Single-select coverage status chips. Always visible; counts appear once
/// coverage has been analyzed. Selecting a status before any analysis exists
/// makes the list show a "run coverage" prompt instead of silently emptying.
class _CoverageFilterRow extends StatelessWidget {
  final CoverageFilter coverageFilter;
  final ValueChanged<CoverageFilter> onCoverageFilterChanged;
  final Map<String, LineCoverageInfo> lineCoverage;
  final int totalLineCount;
  final bool hasCoverageResult;

  const _CoverageFilterRow({
    required this.coverageFilter,
    required this.onCoverageFilterChanged,
    required this.lineCoverage,
    required this.totalLineCount,
    required this.hasCoverageResult,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          'Coverage:',
          style: TextStyle(fontSize: 11, color: AppColors.onSurfaceMuted),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _chip(
                  'All',
                  CoverageFilter.all,
                  hasCoverageResult ? totalLineCount : null,
                ),
                const SizedBox(width: 6),
                _chip(
                  'Covered',
                  CoverageFilter.covered,
                  hasCoverageResult ? countCoveredLines(lineCoverage) : null,
                ),
                const SizedBox(width: 6),
                _chip(
                  'Too shallow',
                  CoverageFilter.tooShallow,
                  hasCoverageResult ? countShallowLines(lineCoverage) : null,
                ),
                const SizedBox(width: 6),
                _chip(
                  'Too deep',
                  CoverageFilter.tooDeep,
                  hasCoverageResult ? countDeepLines(lineCoverage) : null,
                ),
                const SizedBox(width: 6),
                _chip(
                  'Unaccounted',
                  CoverageFilter.unaccounted,
                  hasCoverageResult
                      ? countUnaccountedLines(lineCoverage)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _chip(String label, CoverageFilter filter, int? count) {
    return _CoverageChip(
      label: label,
      filter: filter,
      count: count,
      selected: coverageFilter,
      onChanged: onCoverageFilterChanged,
    );
  }
}

/// One filter toggle. A chip shape is kept because this *is* a control —
/// but selection is shown with weight and a neutral ring, not a hue per
/// filter.
class _CoverageChip extends StatelessWidget {
  final String label;
  final CoverageFilter filter;
  final int? count;
  final CoverageFilter selected;
  final ValueChanged<CoverageFilter> onChanged;

  const _CoverageChip({
    required this.label,
    required this.filter,
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
          color: isSelected
              ? AppColors.onSurfaceSoft.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.onSurfaceSoft : AppColors.outline,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Text(
          count != null ? '$label $count' : label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal,
            color: isSelected ? AppColors.ink : AppColors.onSurfaceSoft,
          ),
        ),
      ),
    );
  }
}
