/// Repertoire Lines Browser Widget
/// A flat, sortable table of all lines in a repertoire with search,
/// toggle filters, per-line stats, and optional coverage annotations.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../chess_core/generation/build_tree_node.dart';
import '../models/repertoire_line.dart';
import 'package:chess_auto_prep/chess_core/generation/trap_line_info.dart';
import '../services/coherence_service.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../services/generation/fen_map.dart';
import '../theme/app_colors.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import '../utils/coverage_helpers.dart';
import 'package:chess_auto_prep/services/line_metrics_helpers.dart';
import '../utils/lines_filter_helpers.dart';
import 'lines/line_filter_controls.dart';
import 'lines/line_metrics_panel.dart';
import 'lines/line_table_layout.dart';
import '../design_system/components/empty_state_placeholder.dart';
import 'lines/line_item_row.dart';

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
    final metricsChanged =
        oldWidget.tree != widget.tree ||
        oldWidget.traps != widget.traps ||
        oldWidget.coherenceResult != widget.coherenceResult;
    if (metricsChanged) {
      _computeLineMetrics();
    }
    if (oldWidget.lines != widget.lines) {
      _displayIndex = buildLineDisplayIndex(
        widget.lines,
        previous: _displayIndex,
        previousLines: oldWidget.lines,
      );
      // Metrics for the lines that are new to the list or were replaced by an
      // edit; lines carried over untouched keep theirs.  A change to one of
      // the shared metric inputs is handled above and re-derives everything.
      if (!metricsChanged) _computeLineMetrics(previousLines: oldWidget.lines);
    }
    // Content compare, not identity: the parent hands us a fresh
    // currentMoveSequence list on every rebuild, so an identity `!=` was
    // always true and re-ran the O(N log N) filter+sort over all lines on
    // every parent repaint. Only an actual move change should re-filter.
    if (oldWidget.lines != widget.lines ||
        !listEquals(
          oldWidget.currentMoveSequence,
          widget.currentMoveSequence,
        ) ||
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

  /// Derives quality metrics for [widget.lines]; with [previousLines] only
  /// the lines that are new or were replaced by an edit are re-derived.
  void _computeLineMetrics({List<RepertoireLine>? previousLines}) {
    _lineMetrics = buildLineMetricsIndex(
      lines: widget.lines,
      treeRoot: widget.tree?.root,
      isWhiteRepertoire: widget.isWhiteRepertoire,
      traps: widget.traps,
      coherenceResult: widget.coherenceResult,
      previous: previousLines == null ? null : _lineMetrics,
      previousLines: previousLines,
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

  /// Renders the current filtered result using the browser's own indexes.
  Widget _buildList(LineTableLayout layout, {required bool needsCoverageRun}) {
    final lines = _filteredLines;
    final inputs = widget;
    final coverage = _lineCoverage;
    final metrics = _lineMetrics;
    final display = _displayIndex;
    if (needsCoverageRun) {
      return _CoverageRunPrompt(
        isCoverageRunning: widget.isCoverageRunning,
        onRunCoverage: widget.onCoveragePressed,
        onResetFilters: _resetAllFilters,
      );
    }

    if (lines.isEmpty) {
      return EmptyStatePlaceholder(
        icon: Icons.search_off,
        iconSize: 48,
        title: _hasActiveFilters
            ? 'No lines match the current filters'
            : 'No lines in repertoire',
        trailing: _hasActiveFilters
            ? TextButton(
                onPressed: _resetAllFilters,
                child: const Text('Show all lines'),
              )
            : null,
      );
    }

    return Column(
      children: [
        _buildTableHeader(layout),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final line = lines[index];
              return LineItemRow(
                line: line,
                index: index,
                layout: layout,
                currentMoveSequence: inputs.currentMoveSequence,
                showCoverage: inputs.coverageResult != null,
                coverageInfo: coverage[line.id],
                metrics: metrics[line.id],
                displayTitle: display[line.id]?.title,
                onLineSelected: inputs.onLineSelected,
                onLineRenamed: inputs.onLineRenamed,
                onLineDeleted: inputs.onLineDeleted,
                onNavigateToPosition: inputs.onNavigateToPosition,
                navigationStack: inputs.navigationStack,
                boardPreview: inputs.boardPreview,
              );
            },
          ),
        ),
      ],
    );
  }

  /// Column headers; click to sort, click again to reverse.
  Widget _buildTableHeader(LineTableLayout layout) {
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
                active: _sortBy == LineSortBy.name,
                ascending: _sortAscending,
                onTap: _onSortChanged,
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
          active: _sortBy == sort,
          ascending: _sortAscending,
          onTap: _onSortChanged,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = LineTableLayout.forWidth(constraints.maxWidth);
        final needsCoverageRun =
            _coverageFilter != CoverageFilter.all &&
            widget.coverageResult == null;

        return Column(
          children: [
            // The filter/metrics block has a fixed natural height; when the
            // pane is short (e.g. the bottom pane's Lines tab) cap it at half
            // the pane and scroll inside instead of overflowing the list.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: (constraints.maxHeight / 2).clamp(0, 320),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
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
                  ],
                ),
              ),
            ),
            Expanded(
              child: _buildList(layout, needsCoverageRun: needsCoverageRun),
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
        height: MediaQuery.sizeOf(context).height * 0.8,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppColors.outline, width: 1),
                ),
              ),
              child: Row(
                children: [
                  const Text(
                    'Browse Repertoire Lines',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
                  fontSize: 12,
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
