/// Slice dialog — filter a PGN game collection by board position and headers.
///
/// The data models ([SliceConfig], [MatchMode], [HeaderFilterConfig]) live in
/// `lib/models/pgn_filter_models.dart` and are re-exported here for backward
/// compatibility. Filter state lives on a [SliceFilterController]; the
/// position / sequence / header filter UIs are the shared widgets under
/// `slice/`, the same ones [InlineSliceEditor] uses.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/slice_filter_controller.dart';
import '../models/pgn_filter_models.dart';
import '../services/pgn_parsing_service.dart' as pgn;
import 'lines_preview_panel.dart';
import 'slice/header_filters.dart';
import 'slice/position_filter.dart';
import 'slice/sequence_filter.dart';

export '../models/pgn_filter_models.dart';

/// Callback signature: passes matching indices + the config that produced them.
typedef SliceApplyCallback = void Function(
    List<int> matchingIndices, SliceConfig config);

class PgnSliceDialog extends StatefulWidget {
  final List<GameRecord> allGames;
  final String currentFen;
  final SliceApplyCallback onApply;

  /// Pre‑populate the dialog from a previously saved config.
  final SliceConfig? initialConfig;

  /// Precomputed FEN → game-index map for instant position lookups.
  final Map<String, List<int>>? fenIndex;

  const PgnSliceDialog({
    super.key,
    required this.allGames,
    required this.currentFen,
    required this.onApply,
    this.initialConfig,
    this.fenIndex,
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
    });
  }

  void _reset() {
    setState(() => _matchingIndices = []);
    // reset() notifies, which schedules the recompute.
    _filters.reset();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Slice Dataset'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PositionFilter(
                controller: _filters,
                currentFen: widget.currentFen,
              ),
              const Divider(),
              SequenceFilter(controller: _filters),
              const Divider(),
              HeaderFilters(controller: _filters),
              const SizedBox(height: 16),
              SizedBox(
                height: 200,
                child: LinesPreviewPanel(
                  allGames: widget.allGames,
                  matchedIndices: _matchingIndices,
                  computing: _computing,
                  maxHeight: 200,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _reset,
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _matchingIndices.isNotEmpty
              ? () {
                  widget.onApply(_matchingIndices, _filters.buildConfig());
                  Navigator.pop(context);
                }
              : null,
          child: Text(_computing
              ? 'Apply (${_matchingIndices.isEmpty ? '…' : _matchingIndices.length})'
              : 'Apply (${_matchingIndices.length})'),
        ),
      ],
    );
  }
}
