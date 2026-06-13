import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../models/repertoire_line.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import '../../utils/coverage_helpers.dart';
import 'package:chess_auto_prep/services/line_metrics_helpers.dart';
import '../layout/empty_state_placeholder.dart';
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
  final BoardPreviewController? boardPreview;
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
    this.boardPreview,
    required this.hasActiveFilters,
    required this.onResetFilters,
  });

  @override
  Widget build(BuildContext context) {
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
            boardPreview: boardPreview,
          );
        },
      );
    }

    final flatEntries = _buildGroupedFlatEntries(
      groupedLines: groupedLines,
      expandedGroups: expandedGroups,
    );

    return ListView.builder(
      controller: scrollController,
      itemCount: flatEntries.length,
      itemBuilder: (context, index) {
        final entry = flatEntries[index];
        return switch (entry) {
          _GroupHeaderEntry(:final groupName, :final lineCount) =>
            _GroupHeader(
              groupName: groupName,
              lineCount: lineCount,
              isExpanded: expandedGroups.contains(groupName),
              onToggle: () => onToggleGroup(groupName),
            ),
          _GroupLineEntry(:final line, :final index) => LineItemRow(
              line: line,
              index: index,
              indented: true,
              isExpanded: isExpanded,
              currentMoveSequence: currentMoveSequence,
              showCoverage: showCoverage,
              coverageInfo: lineCoverage[line.id],
              metrics: lineMetrics[line.id],
              onLineSelected: onLineSelected,
              onLineRenamed: onLineRenamed,
              onNavigateToPosition: onNavigateToPosition,
              navigationStack: navigationStack,
              boardPreview: boardPreview,
            ),
        };
      },
    );
  }
}

List<_GroupedListEntry> _buildGroupedFlatEntries({
  required Map<String, List<RepertoireLine>> groupedLines,
  required Set<String> expandedGroups,
}) {
  final entries = <_GroupedListEntry>[];
  for (final groupName in groupedLines.keys) {
    final lines = groupedLines[groupName]!;
    entries.add(_GroupHeaderEntry(groupName, lines.length));
    if (expandedGroups.contains(groupName)) {
      for (var i = 0; i < lines.length; i++) {
        entries.add(_GroupLineEntry(lines[i], i));
      }
    }
  }
  return entries;
}

sealed class _GroupedListEntry {}

final class _GroupHeaderEntry extends _GroupedListEntry {
  final String groupName;
  final int lineCount;

  _GroupHeaderEntry(this.groupName, this.lineCount);
}

final class _GroupLineEntry extends _GroupedListEntry {
  final RepertoireLine line;
  final int index;

  _GroupLineEntry(this.line, this.index);
}

class _GroupHeader extends StatelessWidget {
  final String groupName;
  final int lineCount;
  final bool isExpanded;
  final VoidCallback onToggle;

  const _GroupHeader({
    required this.groupName,
    required this.lineCount,
    required this.isExpanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.grey[700],
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$lineCount',
                style: TextStyle(fontSize: 11, color: Colors.grey[300]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
