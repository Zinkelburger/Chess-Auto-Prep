/// Repertoire Lines Browser Widget
/// A flat, sortable table of all lines in a repertoire with search,
/// toggle filters, per-line stats, and optional coverage annotations.
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
import 'lines/line_table_layout.dart';
import 'lines/lines_list_panel.dart';

export '../utils/lines_filter_helpers.dart' show CoverageFilter;

class RepertoireLinesBrowser extends StatefulWidget {
  final List<RepertoireLine> lines;
  final List<String> currentMoveSequence;
  final Function(RepertoireLine line)? onLineSelected;
  final Function(RepertoireLine line, String newTitle)? onLineRenamed;
  final Function(RepertoireLine line)? onLineDeleted;

  /// Starts a coverage analysis run (config dialog + run). Wired to the
  /// "Run coverage analysis" prompt shown when a coverage filter is selected
  /// before any analysis exists.
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

  bool _showOnlyMatchingPosition = true;
  LineSortBy _sortBy = LineSortBy.name;
  bool _sortAscending = true;
  CoverageFilter _coverageFilter = CoverageFilter.all;
  final Set<LineMetricsFilter> _metricsFilters = {};

  Map<String, LineCoverageInfo> _lineCoverage = {};
  Map<String, LineQualityInfo> _lineMetrics = {};
  Map<String, LineDisplayData> _displayIndex = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _computeLineCoverage();
    _computeLineMetrics();
    _displayIndex = buildLineDisplayIndex(widget.lines);
    _applyFilters();
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
    if (oldWidget.lines != widget.lines) {
      _displayIndex = buildLineDisplayIndex(widget.lines);
    }
    if (oldWidget.lines != widget.lines ||
        oldWidget.currentMoveSequence != widget.currentMoveSequence ||
        oldWidget.coverageResult != widget.coverageResult ||
        metricsChanged) {
      _applyFilters();
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
      _applyFilters();
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

  void _applyFilters({bool rebuild = true}) {
    final filtered = filterAndSortLines(
      allLines: widget.lines,
      searchTerm: _searchController.text,
      showOnlyMatchingPosition: _showOnlyMatchingPosition,
      currentMoves: widget.currentMoveSequence,
      sortBy: _sortBy,
      sortAscending: _sortAscending,
      coverageFilter: _coverageFilter,
      metricsFilters: _metricsFilters,
      lineCoverage: _lineCoverage,
      lineMetrics: _lineMetrics,
      coverageResult: widget.coverageResult,
      displayIndex: _displayIndex,
    );

    if (rebuild) {
      setState(() => _filteredLines = filtered);
    } else {
      _filteredLines = filtered;
    }
  }

  bool get _hasActiveFilters =>
      _searchController.text.isNotEmpty ||
      _showOnlyMatchingPosition ||
      _coverageFilter != CoverageFilter.all ||
      _metricsFilters.isNotEmpty;

  void _resetAllFilters() {
    _searchDebounce?.cancel();
    setState(() {
      _searchController.clear();
      _showOnlyMatchingPosition = false;
      _coverageFilter = CoverageFilter.all;
      _metricsFilters.clear();
      _applyFilters(rebuild: false);
    });
  }

  /// First click on a stat column sorts "problems first"; a second click
  /// on the same column reverses.
  void _onSortChanged(LineSortBy sort) {
    setState(() {
      if (_sortBy == sort) {
        _sortAscending = !_sortAscending;
      } else {
        _sortBy = sort;
        _sortAscending = switch (sort) {
          LineSortBy.name => true,
          LineSortBy.moves => true,
          // Low ease / low coherence are the lines needing work.
          LineSortBy.ease => true,
          LineSortBy.coherence => true,
          // Most traps first; worst coverage first.
          LineSortBy.traps => false,
          LineSortBy.coverage => false,
        };
      }
    });
    _applyFilters();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = LineTableLayout.forWidth(constraints.maxWidth);
        final needsCoverageRun = _coverageFilter != CoverageFilter.all &&
            widget.coverageResult == null;

        return Column(
          children: [
            LineFilterControls(
              searchController: _searchController,
              showOnlyMatchingPosition: _showOnlyMatchingPosition,
              onShowOnlyMatchingPositionChanged: (value) {
                setState(() => _showOnlyMatchingPosition = value);
                _applyFilters();
              },
              metricsFilters: _metricsFilters,
              onMetricsFilterToggled: (filter, active) {
                setState(() {
                  if (active) {
                    _metricsFilters.add(filter);
                  } else {
                    _metricsFilters.remove(filter);
                  }
                });
                _applyFilters();
              },
              coverageResult: widget.coverageResult,
              coverageFilter: _coverageFilter,
              onCoverageFilterChanged: (filter) {
                setState(() => _coverageFilter = filter);
                _applyFilters();
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
              currentMoveSequence: widget.currentMoveSequence,
              onNavigateToPosition: widget.onNavigateToPosition,
            ),
            Expanded(
              child: LinesListPanel(
                scrollController: _scrollController,
                filteredLines: _filteredLines,
                layout: layout,
                sortBy: _sortBy,
                sortAscending: _sortAscending,
                onSortChanged: _onSortChanged,
                currentMoveSequence: widget.currentMoveSequence,
                showCoverage: widget.coverageResult != null,
                lineCoverage: _lineCoverage,
                lineMetrics: _lineMetrics,
                displayIndex: _displayIndex,
                onLineSelected: widget.onLineSelected,
                onLineRenamed: widget.onLineRenamed,
                onLineDeleted: widget.onLineDeleted,
                onNavigateToPosition: widget.onNavigateToPosition,
                navigationStack: widget.navigationStack,
                boardPreview: widget.boardPreview,
                hasActiveFilters: _hasActiveFilters,
                onResetFilters: _resetAllFilters,
                needsCoverageRun: needsCoverageRun,
                isCoverageRunning: widget.isCoverageRunning,
                onRunCoverage: widget.onCoveragePressed,
              ),
            ),
          ],
        );
      },
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
