/// Repertoire Lines Browser Widget
/// A comprehensive view of all lines in a repertoire with filtering,
/// grouping, detailed previews, and optional coverage annotations
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../models/build_tree_node.dart';
import '../models/repertoire_line.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import '../services/coherence_service.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../services/generation/fen_map.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import '../utils/coverage_helpers.dart';
import 'package:chess_auto_prep/services/line_metrics_helpers.dart';
import '../utils/lines_filter_helpers.dart';
import 'lines/line_filter_controls.dart';
import 'lines/line_metrics_panel.dart';
import 'lines/lines_list_panel.dart';

export '../utils/lines_filter_helpers.dart' show CoverageFilter;

class RepertoireLinesBrowser extends StatefulWidget {
  final List<RepertoireLine> lines;
  final List<String> currentMoveSequence;
  final Function(RepertoireLine line)? onLineSelected;
  final Function(RepertoireLine line, String newTitle)? onLineRenamed;
  final Function(RepertoireLine line)? onLineDeleted;
  final VoidCallback? onCoveragePressed;
  final bool isCoverageRunning;
  final bool isExpanded;
  final CoverageResult? coverageResult;
  final Function(List<String> moveSequence)? onNavigateToPosition;

  /// Optional coverage progress (0.0–1.0) shown during analysis.
  final double? coverageProgress;

  /// Optional coverage progress message shown during analysis.
  final String? coverageProgressMessage;

  final BuildTree? tree;
  final FenMap? fenMap;
  final bool isWhiteRepertoire;
  final List<TrapLineInfo> traps;
  final CoherenceResult? coherenceResult;
  final NavigationStack? navigationStack;
  final BoardPreviewController? boardPreview;

  const RepertoireLinesBrowser({
    super.key,
    required this.lines,
    this.currentMoveSequence = const [],
    this.onLineSelected,
    this.onLineRenamed,
    this.onLineDeleted,
    this.onCoveragePressed,
    this.isCoverageRunning = false,
    this.isExpanded = false,
    this.coverageResult,
    this.onNavigateToPosition,
    this.coverageProgress,
    this.coverageProgressMessage,
    this.tree,
    this.fenMap,
    this.isWhiteRepertoire = true,
    this.traps = const [],
    this.coherenceResult,
    this.navigationStack,
    this.boardPreview,
  });

  @override
  State<RepertoireLinesBrowser> createState() => _RepertoireLinesBrowserState();
}

class _RepertoireLinesBrowserState extends State<RepertoireLinesBrowser> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _searchDebounce;

  List<RepertoireLine> _filteredLines = [];
  Map<String, List<RepertoireLine>> _groupedLines = {};

  /// Groups the user explicitly collapsed. Everything else renders expanded,
  /// so lines are visible without any clicking.
  final Set<String> _collapsedGroups = {};

  bool _showOnlyMatchingPosition = true;
  LineSortBy _sortBy = LineSortBy.name;
  CoverageFilter _coverageFilter = CoverageFilter.all;
  LineMetricsFilter _metricsFilter = LineMetricsFilter.all;

  Map<String, LineCoverageInfo> _lineCoverage = {};
  Map<String, LineQualityInfo> _lineMetrics = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _computeLineCoverage();
    _computeLineMetrics();
    _filterAndGroupLines();
  }

  @override
  void didUpdateWidget(RepertoireLinesBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverageResult != widget.coverageResult) {
      _computeLineCoverage();
    }
    final metricsChanged = oldWidget.tree != widget.tree ||
        oldWidget.traps != widget.traps ||
        oldWidget.coherenceResult != widget.coherenceResult;
    if (metricsChanged) {
      _computeLineMetrics();
    }
    if (oldWidget.lines != widget.lines ||
        oldWidget.currentMoveSequence != widget.currentMoveSequence ||
        oldWidget.coverageResult != widget.coverageResult ||
        metricsChanged) {
      _filterAndGroupLines();
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _filterAndGroupLines();
    });
  }

  void _computeLineCoverage() {
    final result = widget.coverageResult;
    if (result == null) {
      _lineCoverage = {};
      return;
    }
    _lineCoverage = computeLineCoverageMap(widget.lines, result);
  }

  void _computeLineMetrics() {
    _lineMetrics = computeLineMetricsMap(
      lines: widget.lines,
      treeRoot: widget.tree?.root,
      isWhiteRepertoire: widget.isWhiteRepertoire,
      traps: widget.traps,
      coherenceResult: widget.coherenceResult,
    );
  }

  void _filterAndGroupLines({bool rebuild = true}) {
    final result = filterSortAndGroupLines(
      allLines: widget.lines,
      searchTerm: _searchController.text,
      showOnlyMatchingPosition: _showOnlyMatchingPosition,
      currentMoves: widget.currentMoveSequence,
      sortBy: _sortBy,
      coverageFilter: _coverageFilter,
      metricsFilter: _metricsFilter,
      lineCoverage: _lineCoverage,
      lineMetrics: _lineMetrics,
      coverageResult: widget.coverageResult,
    );

    void apply() {
      _filteredLines = result.filtered;
      _groupedLines = result.grouped;
    }

    if (rebuild) {
      setState(apply);
    } else {
      apply();
    }
  }

  bool get _hasActiveFilters =>
      _searchController.text.isNotEmpty ||
      _showOnlyMatchingPosition ||
      _coverageFilter != CoverageFilter.all ||
      _metricsFilter != LineMetricsFilter.all;

  void _resetAllFilters() {
    _searchDebounce?.cancel();
    setState(() {
      _searchController.clear();
      _showOnlyMatchingPosition = false;
      _coverageFilter = CoverageFilter.all;
      _metricsFilter = LineMetricsFilter.all;
      _filterAndGroupLines(rebuild: false);
    });
  }

  void _toggleGroup(String groupName) {
    setState(() {
      if (_collapsedGroups.contains(groupName)) {
        _collapsedGroups.remove(groupName);
      } else {
        _collapsedGroups.add(groupName);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        LineFilterControls(
          searchController: _searchController,
          showOnlyMatchingPosition: _showOnlyMatchingPosition,
          onShowOnlyMatchingPositionChanged: (value) {
            setState(() => _showOnlyMatchingPosition = value);
            _filterAndGroupLines();
          },
          onCoveragePressed: widget.onCoveragePressed,
          isCoverageRunning: widget.isCoverageRunning,
          sortBy: _sortBy,
          onSortByChanged: (value) {
            setState(() => _sortBy = value);
            _filterAndGroupLines();
          },
          metricsFilter: _metricsFilter,
          onMetricsFilterChanged: (value) {
            setState(() => _metricsFilter = value);
            _filterAndGroupLines();
          },
          coverageResult: widget.coverageResult,
          coverageFilter: _coverageFilter,
          onCoverageFilterChanged: (filter) {
            setState(() => _coverageFilter = filter);
            _filterAndGroupLines();
          },
          lineCoverage: _lineCoverage,
          totalLineCount: widget.lines.length,
        ),
        LineMetricsPanel(
          showCoverageProgress: widget.isCoverageRunning,
          coverageProgress: widget.coverageProgress,
          coverageProgressMessage: widget.coverageProgressMessage,
          coverageResult: widget.coverageResult,
          lineCoverage: _lineCoverage,
          filteredLines: _filteredLines,
          groupedLines: _groupedLines,
          currentMoveSequence: widget.currentMoveSequence,
          onNavigateToPosition: widget.onNavigateToPosition,
        ),
        Expanded(
          child: LinesListPanel(
            scrollController: _scrollController,
            filteredLines: _filteredLines,
            groupedLines: _groupedLines,
            expandedGroups: _groupedLines.keys
                .where((g) => !_collapsedGroups.contains(g))
                .toSet(),
            onToggleGroup: _toggleGroup,
            isExpanded: widget.isExpanded,
            currentMoveSequence: widget.currentMoveSequence,
            showCoverage: widget.coverageResult != null,
            lineCoverage: _lineCoverage,
            lineMetrics: _lineMetrics,
            onLineSelected: widget.onLineSelected,
            onLineRenamed: widget.onLineRenamed,
            onLineDeleted: widget.onLineDeleted,
            onNavigateToPosition: widget.onNavigateToPosition,
            navigationStack: widget.navigationStack,
            boardPreview: widget.boardPreview,
            hasActiveFilters: _hasActiveFilters,
            onResetFilters: _resetAllFilters,
          ),
        ),
      ],
    );
  }
}

/// Dialog wrapper for full-screen repertoire lines browser
class RepertoireLinesBrowserDialog extends StatelessWidget {
  final List<RepertoireLine> lines;
  final List<String> currentMoveSequence;
  final Function(RepertoireLine line)? onLineSelected;
  final Function(RepertoireLine line, String newTitle)? onLineRenamed;
  final CoverageResult? coverageResult;

  const RepertoireLinesBrowserDialog({
    super.key,
    required this.lines,
    this.currentMoveSequence = const [],
    this.onLineSelected,
    this.onLineRenamed,
    this.coverageResult,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.8,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.grey[700]!, width: 1),
                ),
              ),
              child: Row(
                children: [
                  const Text(
                    'Browse Repertoire Lines',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: RepertoireLinesBrowser(
                lines: lines,
                currentMoveSequence: currentMoveSequence,
                isExpanded: true,
                coverageResult: coverageResult,
                onLineSelected: (line) {
                  onLineSelected?.call(line);
                  Navigator.of(context).pop();
                },
                onLineRenamed: onLineRenamed,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
