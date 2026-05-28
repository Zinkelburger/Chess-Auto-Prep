import 'package:flutter/material.dart';

import '../../models/repertoire_line.dart';
import '../../services/navigation_stack.dart';
import '../../utils/coverage_helpers.dart';
import '../../utils/line_metrics_helpers.dart';
import 'line_item_row.dart';

/// Scrollable list of repertoire lines, optionally grouped.
class LinesListPanel extends StatelessWidget {
  final ScrollController scrollController;
  final List<RepertoireLine> filteredLines;
  final Map<String, List<RepertoireLine>> groupedLines;
  final Set<String> expandedGroups;
  final ValueChanged<String> onToggleGroup;
  final bool isExpanded;
  final List<String> currentMoveSequence;
  final bool showCoverage;
  final Map<String, LineCoverageInfo> lineCoverage;
  final Map<String, LineQualityInfo> lineMetrics;
  final void Function(RepertoireLine line)? onLineSelected;
  final void Function(RepertoireLine line, String newTitle)? onLineRenamed;
  final void Function(List<String> moveSequence)? onNavigateToPosition;
  final NavigationStack? navigationStack;
  final bool hasActiveFilters;
  final VoidCallback onResetFilters;

  const LinesListPanel({
    super.key,
    required this.scrollController,
    required this.filteredLines,
    required this.groupedLines,
    required this.expandedGroups,
    required this.onToggleGroup,
    this.isExpanded = false,
    this.currentMoveSequence = const [],
    this.showCoverage = false,
    required this.lineCoverage,
    required this.lineMetrics,
    this.onLineSelected,
    this.onLineRenamed,
    this.onNavigateToPosition,
    this.navigationStack,
    required this.hasActiveFilters,
    required this.onResetFilters,
  });

  @override
  Widget build(BuildContext context) {
    if (filteredLines.isEmpty) {
      return _LinesEmptyState(
        hasActiveFilters: hasActiveFilters,
        onResetFilters: onResetFilters,
      );
    }

    if (groupedLines.length <= 1) {
      return ListView.builder(
        controller: scrollController,
        itemCount: filteredLines.length,
        itemBuilder: (context, index) {
          final line = filteredLines[index];
          return LineItemRow(
            line: line,
            index: index,
            isExpanded: isExpanded,
            currentMoveSequence: currentMoveSequence,
            showCoverage: showCoverage,
            coverageInfo: lineCoverage[line.id],
            metrics: lineMetrics[line.id],
            onLineSelected: onLineSelected,
            onLineRenamed: onLineRenamed,
            onNavigateToPosition: onNavigateToPosition,
            navigationStack: navigationStack,
          );
        },
      );
    }

    final groupKeys = groupedLines.keys.toList();

    return ListView.builder(
      controller: scrollController,
      itemCount: groupKeys.length,
      itemBuilder: (context, index) {
        final groupName = groupKeys[index];
        final lines = groupedLines[groupName]!;
        final isGroupExpanded = expandedGroups.contains(groupName);

        return _LineGroupSection(
          groupName: groupName,
          lines: lines,
          isExpanded: isGroupExpanded,
          onToggle: () => onToggleGroup(groupName),
          listIsExpanded: isExpanded,
          currentMoveSequence: currentMoveSequence,
          showCoverage: showCoverage,
          lineCoverage: lineCoverage,
          lineMetrics: lineMetrics,
          onLineSelected: onLineSelected,
          onLineRenamed: onLineRenamed,
          onNavigateToPosition: onNavigateToPosition,
          navigationStack: navigationStack,
        );
      },
    );
  }
}

class _LinesEmptyState extends StatelessWidget {
  final bool hasActiveFilters;
  final VoidCallback onResetFilters;

  const _LinesEmptyState({
    required this.hasActiveFilters,
    required this.onResetFilters,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 48, color: Colors.grey[600]),
            const SizedBox(height: 16),
            Text(
              hasActiveFilters
                  ? 'No lines match the current filters'
                  : 'No lines in repertoire',
              style: TextStyle(color: Colors.grey[500]),
              textAlign: TextAlign.center,
            ),
            if (hasActiveFilters) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: onResetFilters,
                child: const Text('Show all lines'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LineGroupSection extends StatelessWidget {
  final String groupName;
  final List<RepertoireLine> lines;
  final bool isExpanded;
  final VoidCallback onToggle;
  final bool listIsExpanded;
  final List<String> currentMoveSequence;
  final bool showCoverage;
  final Map<String, LineCoverageInfo> lineCoverage;
  final Map<String, LineQualityInfo> lineMetrics;
  final void Function(RepertoireLine line)? onLineSelected;
  final void Function(RepertoireLine line, String newTitle)? onLineRenamed;
  final void Function(List<String> moveSequence)? onNavigateToPosition;
  final NavigationStack? navigationStack;

  const _LineGroupSection({
    required this.groupName,
    required this.lines,
    required this.isExpanded,
    required this.onToggle,
    required this.listIsExpanded,
    required this.currentMoveSequence,
    required this.showCoverage,
    required this.lineCoverage,
    required this.lineMetrics,
    this.onLineSelected,
    this.onLineRenamed,
    this.onNavigateToPosition,
    this.navigationStack,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              border: Border(
                bottom: BorderSide(color: Colors.grey[800]!, width: 1),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isExpanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18,
                  color: Colors.grey[400],
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    groupName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.grey[700],
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${lines.length}',
                    style: TextStyle(fontSize: 11, color: Colors.grey[300]),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (isExpanded)
          ...lines.asMap().entries.map(
                (entry) => LineItemRow(
                  line: entry.value,
                  index: entry.key,
                  indented: true,
                  isExpanded: listIsExpanded,
                  currentMoveSequence: currentMoveSequence,
                  showCoverage: showCoverage,
                  coverageInfo: lineCoverage[entry.value.id],
                  metrics: lineMetrics[entry.value.id],
                  onLineSelected: onLineSelected,
                  onLineRenamed: onLineRenamed,
                  onNavigateToPosition: onNavigateToPosition,
                  navigationStack: navigationStack,
                ),
              ),
      ],
    );
  }
}
