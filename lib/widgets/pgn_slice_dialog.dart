/// Slice dialog — filter a PGN game collection by board position and headers.
///
/// The data models ([SliceConfig], [MatchMode], [HeaderFilterConfig]) live in
/// `lib/models/pgn_filter_models.dart` and are re-exported here for backward
/// compatibility. Filter state lives on a [SliceFilterController]; the
/// position / sequence / header filter UIs are the shared widgets under
/// `slice/`, the same ones [InlineSliceEditor] uses.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/slice_filter_controller.dart';
import '../models/pgn_filter_models.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import '../theme/app_colors.dart';
import 'lines_preview_panel.dart';
import 'slice/header_filters.dart';
import 'slice/position_filter.dart';
import 'slice/sequence_filter.dart';

export '../models/pgn_filter_models.dart';

/// Callback signature: passes matching indices + the config that produced them.
typedef SliceApplyCallback =
    void Function(List<int> matchingIndices, SliceConfig config);

class PgnSliceDialog extends StatefulWidget {
  final List<GameRecord> allGames;
  final String currentFen;
  final SliceApplyCallback onApply;

  /// Pre‑populate the dialog from a previously saved config.
  final SliceConfig? initialConfig;

  /// Precomputed FEN → game-index map for instant position lookups.
  final Map<String, List<int>>? fenIndex;

  /// One-click player presets (e.g. "Kasparov as White") shown at the top.
  final List<({String label, String shortLabel, HeaderFilterConfig filter})>
  presets;

  const PgnSliceDialog({
    super.key,
    required this.allGames,
    required this.currentFen,
    required this.onApply,
    this.initialConfig,
    this.fenIndex,
    this.presets = const [],
  });

  @override
  State<PgnSliceDialog> createState() => _PgnSliceDialogState();
}

class _PgnSliceDialogState extends State<PgnSliceDialog> {
  List<int> _matchingIndices = [];
  bool _computing = false;

  late final SliceFilterController _filters;

  Timer? _recomputeDebounce;
  int _computeGeneration = 0;

  @override
  void initState() {
    super.initState();
    _filters = SliceFilterController(initialConfig: widget.initialConfig);
    _filters.addListener(_onFiltersChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _recompute());
  }

  @override
  void dispose() {
    _recomputeDebounce?.cancel();
    _filters.dispose();
    super.dispose();
  }

  void _onFiltersChanged() {
    // While the sequence input is invalid, keep the last valid results.
    if (_filters.sequenceError != null) return;
    _scheduleRecompute();
  }

  void _scheduleRecompute() {
    _recomputeDebounce?.cancel();
    _recomputeDebounce = Timer(const Duration(milliseconds: 300), _recompute);
  }

  void _recompute() {
    final generation = ++_computeGeneration;
    setState(() => _computing = true);

    unawaited(
      pgn
          .computeSliceMatches(
            games: widget.allGames,
            targetFen: _filters.positionFen,
            filters: _filters.rawHeaderFilters,
            seqGroups: _filters.sequenceGroups,
            seqGap: _filters.sequenceGap,
            fenIndex: widget.fenIndex,
          )
          .then((indices) {
            if (!mounted || generation != _computeGeneration) return;
            setState(() {
              _matchingIndices = indices;
              _computing = false;
            });
          }),
    );
  }

  void _reset() {
    setState(() => _matchingIndices = []);
    // reset() notifies, which schedules the recompute.
    _filters.reset();
  }

  Widget _buildQuickPresets() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Quick starts',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: AppColors.inkSoft,
          ),
        ),
        const SizedBox(height: 8),
        ListenableBuilder(
          listenable: _filters,
          builder: (context, _) => Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final preset in widget.presets)
                FilterChip(
                  label: Text(
                    preset.label,
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: _filters.hasPresetHeaderFilter(
                    preset.filter.field,
                    preset.filter.value,
                  ),
                  onSelected: (_) => _filters.togglePresetHeaderFilter(
                    preset.filter.field,
                    preset.filter.value,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final width = math.min(1040.0, viewport.width - 48);
    final height = math.min(680.0, viewport.height - 48);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 820) {
                    return _buildCompactWorkspace();
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 390, child: _buildFilterColumn()),
                      const VerticalDivider(width: 1),
                      Expanded(child: _buildPreviewColumn()),
                    ],
                  );
                },
              ),
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      color: AppColors.surfaceElevated,
      padding: const EdgeInsets.fromLTRB(22, 18, 14, 16),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.infoTint,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.view_list_outlined, color: AppColors.info),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Explore collection',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  'Shape ${widget.allGames.length} games into a readable set. '
                  'Results update as you type.',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  Widget _buildFilterColumn() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: _buildFilterContents(),
    );
  }

  Widget _buildFilterContents() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.presets.isNotEmpty) ...[
          _buildQuickPresets(),
          const SizedBox(height: 20),
        ],
        PositionFilter(controller: _filters, currentFen: widget.currentFen),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Divider(height: 1),
        ),
        SequenceFilter(controller: _filters),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Divider(height: 1),
        ),
        HeaderFilters(controller: _filters, games: widget.allGames),
      ],
    );
  }

  Widget _buildPreviewColumn() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Live preview',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          const Text(
            'Scan players and openings, search within the matches, or hover '
            'the moves. Saving as a study makes every game its own chapter.',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LinesPreviewPanel(
              allGames: widget.allGames,
              matchedIndices: _matchingIndices,
              computing: _computing,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactWorkspace() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildFilterContents(),
          const SizedBox(height: 16),
          SizedBox(height: 300, child: _buildPreviewColumn()),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    final countLabel = _computing
        ? (_matchingIndices.isEmpty ? 'Finding games…' : 'Updating…')
        : 'Show ${_matchingIndices.length} game${_matchingIndices.length == 1 ? '' : 's'}';
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
      decoration: const BoxDecoration(
        color: AppColors.surfaceElevated,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _reset,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Start over'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: !_computing && _matchingIndices.isNotEmpty
                ? () {
                    widget.onApply(_matchingIndices, _filters.buildConfig());
                    Navigator.pop(context);
                  }
                : null,
            icon: const Icon(Icons.arrow_forward, size: 18),
            label: Text(countLabel),
          ),
        ],
      ),
    );
  }
}
