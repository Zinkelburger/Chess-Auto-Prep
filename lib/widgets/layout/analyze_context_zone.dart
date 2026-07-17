/// Analyze context detail pane (B4 Phase 1 extraction).
///
/// Chip-switched Traps | Eval Tree | Line metrics slots for the side/context
/// column in Analyze mode. Composition only — no [RepertoireController].
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import 'empty_state_placeholder.dart';
import '../../models/repertoire_mode.dart';

class AnalyzeContextZone extends StatefulWidget {
  const AnalyzeContextZone({
    super.key,
    this.trapsContent,
    this.evalTreeContent,
    this.metricsContent,
    this.trapsBuilder,
    this.evalTreeBuilder,
    this.metricsBuilder,
    this.initialView,
    this.onViewChanged,
  }) : assert(
         trapsContent != null ||
             evalTreeContent != null ||
             metricsContent != null ||
             trapsBuilder != null ||
             evalTreeBuilder != null ||
             metricsBuilder != null,
         'Provide at least one context content slot or builder',
       );

  final Widget? trapsContent;
  final Widget? evalTreeContent;
  final Widget? metricsContent;
  final WidgetBuilder? trapsBuilder;
  final WidgetBuilder? evalTreeBuilder;
  final WidgetBuilder? metricsBuilder;
  final AnalyzeContextView? initialView;
  final ValueChanged<AnalyzeContextView>? onViewChanged;

  @override
  State<AnalyzeContextZone> createState() => _AnalyzeContextZoneState();
}

class _AnalyzeContextZoneState extends State<AnalyzeContextZone> {
  late AnalyzeContextView _view;

  bool _hasTrapsSlot() =>
      widget.trapsContent != null || widget.trapsBuilder != null;

  bool _hasEvalTreeSlot() =>
      widget.evalTreeContent != null || widget.evalTreeBuilder != null;

  bool _hasMetricsSlot() =>
      widget.metricsContent != null || widget.metricsBuilder != null;

  List<AnalyzeContextView> get _availableViews => [
    if (_hasTrapsSlot()) AnalyzeContextView.traps,
    if (_hasEvalTreeSlot()) AnalyzeContextView.evalTree,
    if (_hasMetricsSlot()) AnalyzeContextView.metrics,
  ];

  @override
  void initState() {
    super.initState();
    _view = _resolveInitialView();
  }

  @override
  void didUpdateWidget(AnalyzeContextZone oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_availableViews.contains(_view)) {
      _view = _availableViews.first;
    } else if (widget.initialView != oldWidget.initialView &&
        widget.initialView != null &&
        _availableViews.contains(widget.initialView)) {
      _view = widget.initialView!;
    }
  }

  AnalyzeContextView _resolveInitialView() {
    final requested = widget.initialView;
    if (requested != null && _availableViews.contains(requested)) {
      return requested;
    }
    return _availableViews.first;
  }

  void _selectView(AnalyzeContextView view) {
    if (_view == view) return;
    setState(() => _view = view);
    widget.onViewChanged?.call(view);
  }

  @override
  Widget build(BuildContext context) {
    final views = _availableViews;
    if (views.isEmpty) {
      return const EmptyStatePlaceholder(
        icon: Icons.view_sidebar_outlined,
        title: 'No context panels',
        subtitle: 'Provide traps, eval tree, or metrics content slots.',
        iconSize: 36,
      );
    }

    return Column(
      children: [
        if (views.length > 1) ...[
          _buildChipBar(views),
          const Divider(height: 1),
        ],
        Expanded(child: _buildContent()),
      ],
    );
  }

  Widget _buildChipBar(List<AnalyzeContextView> views) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          for (var i = 0; i < views.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            _chip(views[i]),
          ],
        ],
      ),
    );
  }

  Widget _chip(AnalyzeContextView view) {
    final (label, icon) = switch (view) {
      AnalyzeContextView.traps => ('Traps', Icons.warning_amber_rounded),
      AnalyzeContextView.evalTree => ('Eval Tree', Icons.insights),
      AnalyzeContextView.metrics => ('Metrics', Icons.bar_chart),
    };
    final isSelected = _view == view;
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: isSelected ? AppColors.accent : AppColors.onSurfaceMuted,
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
      AnalyzeContextView.traps =>
        widget.trapsContent ?? widget.trapsBuilder!(context),
      AnalyzeContextView.evalTree =>
        widget.evalTreeContent ?? widget.evalTreeBuilder!(context),
      AnalyzeContextView.metrics =>
        widget.metricsContent ?? widget.metricsBuilder!(context),
    };
  }
}
