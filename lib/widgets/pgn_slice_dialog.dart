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
import '../theme/app_text_styles.dart';
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
  final String? collectionName;
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
    this.collectionName,
    this.fenIndex,
    this.presets = const [],
  });

  @override
  State<PgnSliceDialog> createState() => _PgnSliceDialogState();
}

class _PgnSliceDialogState extends State<PgnSliceDialog> {
  List<int> _matchingIndices = [];
  bool _computing = false;
  bool _showPreview = false;
  String? _scheduledConfig;

  bool get _hasFilters => !_filters.buildConfig().isEmpty;
  bool get _invalid =>
      _filters.positionParse.error != null || _filters.sequenceError != null;

  late final SliceFilterController _filters;

  Timer? _recomputeDebounce;
  int _computeGeneration = 0;

  @override
  void initState() {
    super.initState();
    _filters = SliceFilterController(initialConfig: widget.initialConfig);
    _removeEmptyHeaderRows();
    _filters.addListener(_onFiltersChanged);
    _onFiltersChanged();
  }

  @override
  void dispose() {
    _recomputeDebounce?.cancel();
    _filters.dispose();
    super.dispose();
  }

  void _onFiltersChanged() {
    if (!mounted) return;
    final config = _filters.buildConfig().toJsonString();
    // Invalidate old results immediately, including during the typing delay.
    if (config == _scheduledConfig && !_invalid) return;
    _scheduledConfig = _invalid ? null : config;
    _recomputeDebounce?.cancel();
    final generation = ++_computeGeneration;
    setState(() {
      _computing = !_invalid && _hasFilters;
      if (!_hasFilters) {
        _showPreview = false;
        _matchingIndices = List.generate(widget.allGames.length, (i) => i);
      }
    });
    if (_invalid || !_hasFilters) return;
    _recomputeDebounce = Timer(
      const Duration(milliseconds: 300),
      () => _recompute(generation),
    );
  }

  void _recompute(int generation) {
    if (!mounted) return;
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
    if (!mounted) return;
    _filters.reset();
    _removeEmptyHeaderRows();
  }

  void _removeEmptyHeaderRows() {
    for (var i = _filters.headerRows.length - 1; i >= 0; i--) {
      if (_filters.headerRows[i].value.isEmpty) _filters.removeHeaderRow(i);
    }
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
                  onSelected: (_) {
                    if (!mounted) return;
                    _filters.togglePresetHeaderFilter(
                      preset.filter.field,
                      preset.filter.value,
                    );
                  },
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
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
    final width = math.min(_showPreview ? 1100.0 : 560.0, viewport.width - 48);
    final height = math.min(680.0, viewport.height - 48);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        key: const ValueKey('pgn-filter-dialog-content'),
        constraints: BoxConstraints(maxWidth: width, maxHeight: height),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            Flexible(
              child: !_showPreview
                  ? _buildFilterColumn()
                  : SizedBox(
                      height: height,
                      child: width < 960
                          ? _buildCompactWorkspace()
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  width: 520,
                                  child: _buildFilterColumn(),
                                ),
                                const VerticalDivider(width: 1),
                                Expanded(child: _buildPreviewColumn()),
                              ],
                            ),
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
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Filter games', style: AppTextStyles.title),
                const SizedBox(height: 2),
                Text(
                  '${widget.collectionName ?? 'This collection'} · ${widget.allGames.length} games',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.muted,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Close',
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterColumn() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: _buildFilterContents(),
    );
  }

  Widget _buildFilterContents() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.presets.isNotEmpty) ...[
          _buildQuickPresets(),
          const SizedBox(height: 12),
        ],
        HeaderFilters(controller: _filters, games: widget.allGames),
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          dense: true,
          minTileHeight: 32,
          visualDensity: VisualDensity.compact,
          initiallyExpanded:
              _filters.hasPositionFilter || _filters.hasSequenceFilter,
          title: const Text('Advanced', style: AppTextStyles.body),
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 12),
              child: PositionFilter(
                controller: _filters,
                currentFen: widget.currentFen,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              child: SequenceFilter(controller: _filters),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPreviewColumn() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Matching games',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          const Text(
            'Games that match all your filters.',
            style: AppTextStyles.caption,
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
          const SizedBox(height: 8),
          SizedBox(height: 300, child: _buildPreviewColumn()),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    final countLabel = _invalid
        ? 'Check filters'
        : _computing
        ? (_matchingIndices.isEmpty ? 'Finding games…' : 'Updating…')
        : 'Show ${_matchingIndices.length} game${_matchingIndices.length == 1 ? '' : 's'}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.surfaceElevated,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      // Counts change width while matching, and desktop windows can be narrow.
      // Keep every action visible by wrapping instead of squeezing the labels.
      child: OverflowBar(
        alignment: MainAxisAlignment.spaceBetween,
        overflowAlignment: OverflowBarAlignment.end,
        spacing: 8,
        overflowSpacing: 4,
        children: [
          TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.standard,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(0, 36),
            ),
            onPressed: _reset,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Clear filters'),
          ),
          if (_hasFilters)
            IconButton(
              tooltip: _showPreview ? 'Hide preview' : 'Preview matching games',
              isSelected: _showPreview,
              icon: const Icon(Icons.visibility_outlined, size: 20),
              selectedIcon: const Icon(Icons.visibility_off_outlined, size: 20),
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              padding: const EdgeInsets.all(8),
              onPressed: () {
                if (!mounted) return;
                setState(() => _showPreview = !_showPreview);
              },
            ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.standard,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: !_invalid && !_computing && _matchingIndices.isNotEmpty
                ? () {
                    if (!mounted) return;
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
