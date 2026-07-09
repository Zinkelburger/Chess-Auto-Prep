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

  /// Sort and metrics-filter live behind this dialog: the browser often sits
  /// in a ~280px side panel where rows of chips overflow, so only the search
  /// box and the position toggle stay inline.
  void _openSortFilterDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        var localSort = sortBy;
        var localFilter = metricsFilter;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Sort and Filter Lines'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sort lines by',
                        style: Theme.of(context).textTheme.titleSmall),
                    RadioGroup<LineSortBy>(
                      groupValue: localSort,
                      onChanged: (v) {
                        if (v == null) return;
                        setDialogState(() => localSort = v);
                        onSortByChanged(v);
                      },
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final (label, value) in const [
                            ('Name', LineSortBy.name),
                            ('Quality', LineSortBy.quality),
                            ('Playability', LineSortBy.playability),
                            ('Traps', LineSortBy.traps),
                            ('Coherence', LineSortBy.coherence),
                            ('Length', LineSortBy.length),
                          ])
                            RadioListTile<LineSortBy>(
                              title: Text(label),
                              value: value,
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('Show only lines with',
                        style: Theme.of(context).textTheme.titleSmall),
                    RadioGroup<LineMetricsFilter>(
                      groupValue: localFilter,
                      onChanged: (v) {
                        if (v == null) return;
                        setDialogState(() => localFilter = v);
                        onMetricsFilterChanged(v);
                      },
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final (label, value) in const [
                            ('Everything', LineMetricsFilter.all),
                            ('Hard moves', LineMetricsFilter.hardMoves),
                            ('Traps', LineMetricsFilter.trappy),
                            ('Low coherence', LineMetricsFilter.lowCoherence),
                          ])
                            RadioListTile<LineMetricsFilter>(
                              title: Text(label),
                              value: value,
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String get _metricsFilterLabel => switch (metricsFilter) {
        LineMetricsFilter.all => '',
        LineMetricsFilter.hardMoves => 'Hard moves',
        LineMetricsFilter.trappy => 'Traps',
        LineMetricsFilter.lowCoherence => 'Low coherence',
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Colors.grey[700]!, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: searchController,
            decoration: InputDecoration(
              hintText: 'Search by name or moves...',
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
          // Wrap, not Row: the browser must survive narrow side-panel widths
          // without overflowing.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                label: const Text('Current Position'),
                selected: showOnlyMatchingPosition,
                onSelected: onShowOnlyMatchingPositionChanged,
                labelStyle: const TextStyle(fontSize: 11),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
              ),
              ActionChip(
                avatar: Icon(Icons.tune, size: 14, color: Colors.grey[400]),
                label: const Text('Sort & Filter'),
                labelStyle: const TextStyle(fontSize: 11),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
                onPressed: () => _openSortFilterDialog(context),
              ),
              // Active advanced filter stays visible (and removable) even
              // though the knob itself lives in the dialog.
              if (metricsFilter != LineMetricsFilter.all)
                InputChip(
                  label: Text('Only: $_metricsFilterLabel'),
                  labelStyle: const TextStyle(fontSize: 11),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  visualDensity: VisualDensity.compact,
                  selected: true,
                  onDeleted: () =>
                      onMetricsFilterChanged(LineMetricsFilter.all),
                ),
              if (onCoveragePressed != null)
                ActionChip(
                  avatar: isCoverageRunning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.analytics_outlined,
                          size: 14, color: Colors.grey[400]),
                  label: Text(isCoverageRunning ? 'Analyzing...' : 'Coverage'),
                  labelStyle: const TextStyle(fontSize: 11),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  visualDensity: VisualDensity.compact,
                  onPressed: isCoverageRunning ? null : onCoveragePressed,
                ),
            ],
          ),
        ],
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
