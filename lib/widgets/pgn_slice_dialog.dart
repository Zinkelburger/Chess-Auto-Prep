/// Slice dialog — filter a PGN game collection by board position and headers.
///
/// The data models ([SliceConfig], [MatchMode], [HeaderFilterConfig]) now live
/// in `lib/models/pgn_filter_models.dart` and are re-exported here for
/// backward compatibility. The position / sequence / header filter UIs are the
/// shared widgets under `slice/`, the same ones [InlineSliceEditor] uses.
library;

import 'dart:async';

import 'package:flutter/material.dart';

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

  /// Active initial config; cleared (null) by Reset. Drives the filter widgets'
  /// pre-population. New [GlobalKey]s force them to rebuild from this on reset.
  SliceConfig? _initial;

  GlobalKey<PositionFilterState> _positionKey = GlobalKey();
  GlobalKey<SequenceFilterState> _sequenceKey = GlobalKey();
  GlobalKey<HeaderFiltersState> _headerKey = GlobalKey();

  Timer? _recomputeDebounce;
  int _computeGeneration = 0;

  @override
  void initState() {
    super.initState();
    _initial = widget.initialConfig;
    // Filter states aren't mounted until after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _recompute());
  }

  @override
  void dispose() {
    _recomputeDebounce?.cancel();
    super.dispose();
  }

  void _scheduleRecompute() {
    _recomputeDebounce?.cancel();
    _recomputeDebounce = Timer(const Duration(milliseconds: 300), _recompute);
  }

  void _recompute() {
    final generation = ++_computeGeneration;
    setState(() => _computing = true);

    final positionFen = _positionKey.currentState?.parsedFen;
    final headerFilters = _headerKey.currentState?.rawFilters ?? const [];
    final seqState = _sequenceKey.currentState;
    final seqGroups = seqState?.groups ?? const <List<String>>[];
    final seqGap = seqState?.gap ?? 4;

    pgn
        .computeSliceMatches(
      games: widget.allGames,
      targetFen: positionFen,
      filters: headerFilters,
      seqGroups: seqGroups,
      seqGap: seqGap,
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

  SliceConfig _buildConfig() {
    final seqState = _sequenceKey.currentState;
    return SliceConfig(
      positionInput: _positionKey.currentState?.parsedFen,
      headerFilters: _headerKey.currentState?.configs ?? const [],
      sequencePattern: seqState?.hasFilter == true
          ? seqState!.groups.map((g) => g.join(' ')).join(' [gap] ')
          : null,
      sequenceGap: seqState?.gap ?? 4,
    );
  }

  void _reset() {
    setState(() {
      _initial = null;
      // Fresh keys force the filter widgets to rebuild with empty state.
      _positionKey = GlobalKey();
      _sequenceKey = GlobalKey();
      _headerKey = GlobalKey();
      _matchingIndices = [];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _recompute());
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
                key: _positionKey,
                currentFen: widget.currentFen,
                initialValue: _initial?.positionInput,
                onChanged: (_) => _scheduleRecompute(),
              ),
              const Divider(),
              SequenceFilter(
                key: _sequenceKey,
                initialPattern: _initial?.sequencePattern,
                initialGap: _initial?.sequenceGap ?? 4,
                onChanged: _scheduleRecompute,
              ),
              const Divider(),
              HeaderFilters(
                key: _headerKey,
                initialFilters: _initial?.headerFilters,
                onChanged: _scheduleRecompute,
              ),
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
                  widget.onApply(_matchingIndices, _buildConfig());
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
