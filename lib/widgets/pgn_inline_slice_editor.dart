/// Inline slice editor for a single PGN source.
///
/// Shows a radio toggle (All Lines / Slice) and, when Slice is selected,
/// the shared filter widgets (position, headers, sequence) with Apply and
/// an embedded [LinesPreviewPanel].
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/board_preview_controller.dart';
import '../core/slice_filter_controller.dart';
import '../models/pgn_filter_models.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import 'lines_preview_panel.dart';
import 'slice/header_filters.dart';
import 'slice/position_filter.dart';
import 'slice/sequence_filter.dart';

/// Callback when slice is applied or cleared.
typedef SliceResultCallback =
    void Function(List<int>? matchedIndices, SliceConfig? config);

/// Compact, expandable slice editor for one PGN source.
class InlineSliceEditor extends StatefulWidget {
  /// All games from this source.
  final List<GameRecord> allGames;

  /// Pre-existing slice config (null = All Lines).
  final SliceConfig? initialConfig;

  /// Current board FEN (for "Board position" chip in position filter).
  final String? currentFen;

  /// Called when the user applies or clears the slice.
  final SliceResultCallback onResult;

  /// Precomputed FEN → game-index map for instant position lookups.
  final Map<String, List<int>>? fenIndex;

  /// Board preview controller for the lines preview hover.
  final BoardPreviewController? boardPreview;

  /// Owner tag for floating board preview.
  final Object? ownerTag;

  const InlineSliceEditor({
    super.key,
    required this.allGames,
    this.initialConfig,
    this.currentFen,
    required this.onResult,
    this.fenIndex,
    this.boardPreview,
    this.ownerTag,
  });

  @override
  State<InlineSliceEditor> createState() => _InlineSliceEditorState();
}

enum _SliceMode { allLines, slice }

class _InlineSliceEditorState extends State<InlineSliceEditor> {
  late _SliceMode _mode;
  List<int> _matchedIndices = [];
  bool _computing = false;
  bool _showPreview = false;

  late final SliceFilterController _filters;

  Timer? _recomputeDebounce;
  int _computeGeneration = 0;

  @override
  void initState() {
    super.initState();
    _filters = SliceFilterController(initialConfig: widget.initialConfig);
    _filters.addListener(_onFiltersChanged);
    _mode = (widget.initialConfig != null && !widget.initialConfig!.isEmpty)
        ? _SliceMode.slice
        : _SliceMode.allLines;
    if (_mode == _SliceMode.slice) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _recompute());
    }
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
            _matchedIndices = indices;
            _computing = false;
          });
        });
  }

  void _applySlice() {
    widget.onResult(_matchedIndices, _filters.buildConfig());
  }

  void _clearSlice() {
    setState(() {
      _mode = _SliceMode.allLines;
      _matchedIndices = [];
      _showPreview = false;
    });
    widget.onResult(null, null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Radio toggle
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                _RadioChip(
                  label: 'All Lines',
                  selected: _mode == _SliceMode.allLines,
                  onTap: () {
                    if (_mode != _SliceMode.allLines) _clearSlice();
                  },
                ),
                const SizedBox(width: 8),
                _RadioChip(
                  label: 'Slice',
                  selected: _mode == _SliceMode.slice,
                  onTap: () {
                    if (_mode != _SliceMode.slice) {
                      setState(() => _mode = _SliceMode.slice);
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _recompute(),
                      );
                    }
                  },
                ),
                const Spacer(),
                if (_mode == _SliceMode.slice) ...[
                  Text(
                    _computing
                        ? 'Computing...'
                        : '${_matchedIndices.length}/${widget.allGames.length}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _computing
                          ? cs.onSurfaceVariant
                          : _matchedIndices.isEmpty
                          ? cs.error
                          : cs.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 28,
                    child: FilledButton.tonal(
                      onPressed: _matchedIndices.isNotEmpty
                          ? _applySlice
                          : null,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        textStyle: const TextStyle(fontSize: 11),
                      ),
                      child: const Text('Apply'),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Slice filters (expandable)
          if (_mode == _SliceMode.slice) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PositionFilter(
                    controller: _filters,
                    currentFen: widget.currentFen,
                  ),
                  const SizedBox(height: 12),
                  SequenceFilter(controller: _filters),
                  const SizedBox(height: 12),
                  HeaderFilters(controller: _filters, games: widget.allGames),
                ],
              ),
            ),

            // Preview toggle + panel
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _showPreview = !_showPreview),
                    icon: Icon(
                      _showPreview ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                    ),
                    label: Text(
                      _showPreview ? 'Hide lines' : 'Preview lines',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            if (_showPreview)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: SizedBox(
                  height: 240,
                  child: LinesPreviewPanel(
                    allGames: widget.allGames,
                    matchedIndices: _matchedIndices,
                    computing: _computing,
                    boardPreview: widget.boardPreview,
                    ownerTag: widget.ownerTag,
                    maxHeight: 220,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _RadioChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _RadioChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? cs.primary.withValues(alpha: 0.5)
                : cs.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 14,
              color: selected ? cs.primary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
