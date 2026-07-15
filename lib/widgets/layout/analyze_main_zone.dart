/// Main analyze work area in Analyze mode (B4 Phase 1 extraction).
///
/// Chip-switched [Lines] | [Coverage] container. Pass content via slots,
/// builders, or [AnalyzeMainZone.withLinesBrowser] for the default lines list.
library;

import 'package:flutter/material.dart';

import '../../models/build_tree_node.dart';
import '../../models/repertoire_line.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import '../../services/coherence_service.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../../services/generation/fen_map.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import '../repertoire_lines_browser.dart';
import 'empty_state_placeholder.dart';
import 'repertoire_mode.dart';

class AnalyzeMainZone extends StatefulWidget {
  const AnalyzeMainZone({
    super.key,
    this.linesContent,
    this.coverageContent,
    this.linesBuilder,
    this.coverageBuilder,
    this.initialView = AnalyzeMainView.lines,
    this.onViewChanged,
  }) : assert(
         linesContent != null || linesBuilder != null,
         'Provide linesContent or linesBuilder',
       );

  /// Default lines tab wraps [RepertoireLinesBrowser]; coverage slot is optional.
  factory AnalyzeMainZone.withLinesBrowser({
    Key? key,
    required List<RepertoireLine> lines,
    List<String> currentMoveSequence = const [],
    void Function(RepertoireLine line)? onLineSelected,
    Future<void> Function(RepertoireLine line, String newTitle)? onLineRenamed,
    VoidCallback? onCoveragePressed,
    bool isCoverageRunning = false,
    bool isExpanded = true,
    CoverageResult? coverageResult,
    void Function(List<String> moveSequence)? onNavigateToPosition,
    double? coverageProgress,
    String? coverageProgressMessage,
    BuildTree? tree,
    FenMap? fenMap,
    bool isWhiteRepertoire = true,
    List<TrapLineInfo> traps = const [],
    CoherenceResult? coherenceResult,
    NavigationStack? navigationStack,
    Widget? coverageContent,
    WidgetBuilder? coverageBuilder,
    AnalyzeMainView initialView = AnalyzeMainView.lines,
    ValueChanged<AnalyzeMainView>? onViewChanged,
  }) {
    return AnalyzeMainZone(
      key: key,
      linesContent: RepertoireLinesBrowser(
        lines: lines,
        currentMoveSequence: currentMoveSequence,
        onLineSelected: onLineSelected,
        onLineRenamed: onLineRenamed,
        onCoveragePressed: onCoveragePressed,
        isCoverageRunning: isCoverageRunning,
        isExpanded: isExpanded,
        coverageResult: coverageResult,
        onNavigateToPosition: onNavigateToPosition,
        coverageProgress: coverageProgress,
        coverageProgressMessage: coverageProgressMessage,
        tree: tree,
        fenMap: fenMap,
        isWhiteRepertoire: isWhiteRepertoire,
        traps: traps,
        coherenceResult: coherenceResult,
        navigationStack: navigationStack,
      ),
      coverageContent: coverageContent,
      coverageBuilder: coverageBuilder,
      initialView: initialView,
      onViewChanged: onViewChanged,
    );
  }

  final Widget? linesContent;
  final Widget? coverageContent;
  final WidgetBuilder? linesBuilder;
  final WidgetBuilder? coverageBuilder;
  final AnalyzeMainView initialView;
  final ValueChanged<AnalyzeMainView>? onViewChanged;

  @override
  State<AnalyzeMainZone> createState() => _AnalyzeMainZoneState();
}

class _AnalyzeMainZoneState extends State<AnalyzeMainZone> {
  late AnalyzeMainView _view;

  @override
  void initState() {
    super.initState();
    _view = widget.initialView;
  }

  @override
  void didUpdateWidget(AnalyzeMainZone oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialView != widget.initialView) {
      _view = widget.initialView;
    }
  }

  void _selectView(AnalyzeMainView view) {
    if (_view == view) return;
    setState(() => _view = view);
    widget.onViewChanged?.call(view);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildChipBar(),
        const Divider(height: 1),
        Expanded(child: _buildContent()),
      ],
    );
  }

  Widget _buildChipBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          _chip('Lines', AnalyzeMainView.lines, Icons.list_alt),
          const SizedBox(width: 6),
          _chip('Coverage', AnalyzeMainView.coverage, Icons.pie_chart_outline),
        ],
      ),
    );
  }

  Widget _chip(String label, AnalyzeMainView view, IconData icon) {
    final isSelected = _view == view;
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: isSelected ? Colors.teal : Colors.grey[500],
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
      selected: isSelected,
      onSelected: (_) => _selectView(view),
      visualDensity: VisualDensity.compact,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _buildContent() {
    return switch (_view) {
      AnalyzeMainView.lines =>
        widget.linesContent ?? widget.linesBuilder!(context),
      AnalyzeMainView.coverage =>
        widget.coverageContent ??
            widget.coverageBuilder?.call(context) ??
            const EmptyStatePlaceholder(
              icon: Icons.pie_chart_outline,
              title: 'No coverage view',
              subtitle:
                  'Provide coverageContent or coverageBuilder for this tab.',
              iconSize: 36,
            ),
    };
  }
}
