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
          size: 18,
          color: AppColors.onSurfaceMuted,
        ),
        suffixIcon: searchController.text.isNotEmpty
            ? IconButton(
                icon: const Icon(
                  Icons.clear,
                  size: 18,
                  color: AppColors.onSurfaceMuted,
                ),
                onPressed: searchController.clear,
              )
            : null,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.info),
        ),
        filled: true,
        fillColor: AppColors.surfaceInset,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
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
                  null,
                  hasCoverageResult ? totalLineCount : null,
                ),
                const SizedBox(width: 6),
                _chip(
                  'Covered',
                  CoverageFilter.covered,
                  AppColors.coverageCovered,
                  hasCoverageResult ? countCoveredLines(lineCoverage) : null,
                ),
                const SizedBox(width: 6),
                _chip(
                  'Too shallow',
                  CoverageFilter.tooShallow,
                  AppColors.coverageShallow,
                  hasCoverageResult ? countShallowLines(lineCoverage) : null,
                ),
                const SizedBox(width: 6),
                _chip(
                  'Too deep',
                  CoverageFilter.tooDeep,
                  AppColors.coverageDeep,
                  hasCoverageResult ? countDeepLines(lineCoverage) : null,
                ),
                const SizedBox(width: 6),
                _chip(
                  'Unaccounted',
                  CoverageFilter.unaccounted,
                  AppColors.coverageUnaccounted,
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

  Widget _chip(String label, CoverageFilter filter, Color? color, int? count) {
    return _CoverageChip(
      label: label,
      filter: filter,
      color: color,
      count: count,
      selected: coverageFilter,
      onChanged: onCoverageFilterChanged,
    );
  }
}

class _CoverageChip extends StatelessWidget {
  final String label;
  final CoverageFilter filter;
  final Color? color;
  final int? count;
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
          color: isSelected
              ? (color ?? AppColors.info)
              : AppColors.chipInactiveBg,
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
                color: isSelected
                    ? AppColors.onWarning
                    : AppColors.onSurfaceSoft,
              ),
            ),
            if (count != null) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppColors.ink.withValues(alpha: 0.25)
                      : AppColors.outline,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: isSelected ? AppColors.onWarning : AppColors.ink,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
