/// A persistent, full-width collection search: editable conditions, position
/// setup and live results. The host owns tab navigation and applying the draft.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/board_editor_controller.dart';
import '../../core/slice_filter_controller.dart';
import '../../models/pgn_filter_models.dart';
import '../../services/pgn_parsing_service.dart' as pgn;
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../board_editor/board_editor_panel.dart';
import '../lines_preview_panel.dart';
import '../slice/header_filters.dart';
import '../slice/position_filter.dart';
import '../slice/sequence_filter.dart';

typedef SliceApplyCallback =
    void Function(List<int> matchingIndices, SliceConfig config);

class PgnGameFilterWorkspace extends StatefulWidget {
  const PgnGameFilterWorkspace({
    super.key,
    required this.allGames,
    required this.currentFen,
    required this.onApply,
    this.onOpenGame,
    this.initialConfig,
    this.collectionName,
    this.fenIndex,
    this.presets = const [],
  });

  final List<GameRecord> allGames;
  final String currentFen;
  final String? collectionName;
  final SliceApplyCallback onApply;
  final void Function(List<int> indices, SliceConfig config, int gameIndex)?
  onOpenGame;
  final SliceConfig? initialConfig;
  final Map<String, List<int>>? fenIndex;
  final List<({String label, String shortLabel, HeaderFilterConfig filter})>
  presets;

  @override
  State<PgnGameFilterWorkspace> createState() => _PgnGameFilterWorkspaceState();
}

class _PgnGameFilterWorkspaceState extends State<PgnGameFilterWorkspace> {
  late SliceFilterController _filters;
  late String _initialConfigJson;
  BoardEditorController? _board;
  String? _boardBaseline;
  bool _boardDirty = false;
  List<int> _matchingIndices = [];
  bool _computing = false;
  String? _computeError;
  String? _scheduledConfig;
  final _filterScroll = ScrollController();
  Timer? _debounce;
  int _generation = 0;

  bool get _hasFilters => !_filters.buildConfig().isEmpty;
  bool get _invalid =>
      _filters.positionParse.error != null ||
      _filters.sequenceError != null ||
      _filters.headerRows.any((row) {
        if (row.mode != MatchMode.regex || row.value.isEmpty) return false;
        try {
          RegExp(row.value);
          return false;
        } on FormatException {
          return true;
        }
      });
  bool get _canApply =>
      !_invalid && !_computing && _board == null && _computeError == null;

  @override
  void initState() {
    super.initState();
    _initialConfigJson = (widget.initialConfig ?? const SliceConfig.empty())
        .toJsonString();
    _filters = SliceFilterController(initialConfig: widget.initialConfig);
    _removeEmptyRows();
    if (_filters.hasSequenceFilter) _filters.validateSequence();
    _filters.addListener(_onFiltersChanged);
    _onFiltersChanged();
  }

  @override
  void didUpdateWidget(covariant PgnGameFilterWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incomingConfig = (widget.initialConfig ?? const SliceConfig.empty())
        .toJsonString();
    if (incomingConfig != _initialConfigJson) {
      // A saved slice can arrive after a new file's first frame. Refresh only
      // an untouched draft; user edits on this tab always take precedence.
      final untouched =
          _board == null &&
          !_invalid &&
          _filters.buildConfig().toJsonString() == _initialConfigJson;
      _initialConfigJson = incomingConfig;
      if (untouched) {
        final previous = _filters;
        previous.removeListener(_onFiltersChanged);
        _filters = SliceFilterController(initialConfig: widget.initialConfig);
        _removeEmptyRows();
        if (_filters.hasSequenceFilter) _filters.validateSequence();
        _filters.addListener(_onFiltersChanged);
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
        _scheduledConfig = null;
        _onFiltersChanged();
      }
    }
    if (!identical(oldWidget.allGames, widget.allGames)) {
      _scheduledConfig = null;
      _onFiltersChanged();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _filterScroll.dispose();
    _board?.dispose();
    _filters.dispose();
    super.dispose();
  }

  void _onFiltersChanged() {
    if (!mounted) return;
    final config = _filters.buildConfig().toJsonString();
    // Even an empty row needs to appear; only computation is deduplicated.
    setState(() {});
    if (config == _scheduledConfig && !_invalid) return;
    _scheduledConfig = _invalid ? null : config;
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _computeError = null;
      _computing = !_invalid && _hasFilters;
      _matchingIndices = _hasFilters || _invalid
          ? []
          : List.generate(widget.allGames.length, (i) => i);
    });
    if (_invalid || !_hasFilters) return;
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_recompute(generation)),
    );
  }

  Future<void> _recompute(int generation) async {
    if (!mounted) return;
    try {
      final indices = await pgn.computeSliceMatches(
        games: widget.allGames,
        targetFen: _filters.positionFen,
        filters: _filters.rawHeaderFilters,
        seqGroups: _filters.sequenceGroups,
        seqGap: _filters.sequenceGap,
        fenIndex: widget.fenIndex,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _matchingIndices = indices;
        _computing = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _computeError = 'Could not search these games. Try again.';
        _computing = false;
      });
    }
  }

  void _removeEmptyRows() {
    for (var i = _filters.headerRows.length - 1; i >= 0; i--) {
      if (_filters.headerRows[i].value.isEmpty) _filters.removeHeaderRow(i);
    }
  }

  void _reset() {
    if (!mounted) return;
    _closeBoard();
    _filters.reset();
    _removeEmptyRows();
  }

  void _editBoard() {
    if (!mounted || _board != null) return;
    final editor = BoardEditorController(
      initialFen: _filters.positionFen ?? widget.currentFen,
    );
    _boardBaseline = editor.fen;
    editor.addListener(_onBoardChanged);
    setState(() => _board = editor);
  }

  void _onBoardChanged() {
    if (!mounted) return;
    setState(
      () => _boardDirty =
          _board!.fen != _boardBaseline || _board!.hasUnappliedFen,
    );
  }

  void _closeBoard() {
    if (!mounted) return;
    final editor = _board;
    setState(() {
      _board = null;
      _boardDirty = false;
      _boardBaseline = null;
    });
    // Children detach their listeners during the next build.
    if (editor != null) {
      editor.removeListener(_onBoardChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) => editor.dispose());
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Find your next game', style: AppTextStyles.title),
              const SizedBox(height: 4),
              Text(
                '${widget.collectionName ?? 'This collection'} · ${widget.allGames.length} games',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.muted,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 1000) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildFilters(),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: _board == null ? 360 : 660,
                        child: _buildResults(),
                      ),
                    ],
                  ),
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: math.min(680, constraints.maxWidth * .57),
                    child: Scrollbar(
                      controller: _filterScroll,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _filterScroll,
                        padding: const EdgeInsets.all(24),
                        child: _buildFilters(),
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: _buildResults(),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        _buildFooter(),
      ],
    ),
  );

  Widget _buildFilters() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.presets.isNotEmpty) ...[
        const Text('Start with a player', style: AppTextStyles.bodyStrong),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in widget.presets)
              FilterChip(
                label: Text(preset.label),
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
                  _removeEmptyRows();
                },
              ),
          ],
        ),
        const SizedBox(height: 16),
      ],
      const Text('Game details', style: AppTextStyles.bodyStrong),
      const SizedBox(height: 4),
      const Text(
        'Match all filled rows. Type part of a name or choose a value from this collection.',
        style: AppTextStyles.caption,
      ),
      const SizedBox(height: 12),
      HeaderFilters(controller: _filters, games: widget.allGames, simple: true),
      const SizedBox(height: 20),
      const Divider(height: 1),
      const SizedBox(height: 16),
      IgnorePointer(
        ignoring: _board != null,
        child: Opacity(
          opacity: _board == null ? 1 : .5,
          child: PositionFilter(controller: _filters),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ActionChip(
            label: const Text('Current position'),
            tooltip: 'Use the board position from the tab you came from',
            onPressed: _board != null
                ? null
                : () {
                    if (!mounted) return;
                    _filters.setPositionFen(widget.currentFen);
                  },
          ),
          OutlinedButton.icon(
            onPressed: _board == null ? _editBoard : null,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Set up a board'),
          ),
          ActionChip(
            label: const Text('King’s Indian'),
            tooltip:
                'Set the position after 1.d4 Nf6 2.c4 g6 3.Nc3 Bg7 4.e4 d6',
            onPressed: _board != null
                ? null
                : () {
                    if (!mounted) return;
                    _filters.positionText.text =
                        '1. d4 Nf6 2. c4 g6 3. Nc3 Bg7 4. e4 d6';
                  },
          ),
        ],
      ),
      const SizedBox(height: 8),
      const Text(
        'Matches the whole position anywhere in a game, including variations: '
        'all pieces, side to move, castling and en passant.',
        style: AppTextStyles.caption,
      ),
      const SizedBox(height: 12),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text(
          'Move sequence · advanced',
          style: AppTextStyles.body,
        ),
        initiallyExpanded: _filters.hasSequenceFilter,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: SequenceFilter(controller: _filters),
          ),
        ],
      ),
    ],
  );

  Widget _buildResults() {
    if (_board case final editor?) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Set up your position',
                  style: AppTextStyles.bodyStrong,
                ),
              ),
              TextButton(
                onPressed: _closeBoard,
                child: const Text('Discard setup'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: BoardEditorPanel(
              controller: editor,
              maxBoardSize: (MediaQuery.sizeOf(context).height - 470).clamp(
                200,
                340,
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: editor.validPosition == null
                ? null
                : () {
                    if (!mounted) return;
                    final position = editor.validPosition;
                    if (position == null) return;
                    _filters.setPositionFen(position.fen);
                    _closeBoard();
                  },
            child: const Text('Use this position'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _computing
              ? 'Finding games…'
              : _invalid || _boardDirty
              ? 'Preview paused'
              : '${_matchingIndices.length} matching games',
          style: AppTextStyles.bodyStrong,
        ),
        const SizedBox(height: 4),
        Text(
          _boardDirty
              ? 'Use this position or discard the setup to continue.'
              : _invalid
              ? 'Check the highlighted filters to continue.'
              : _hasFilters
              ? 'Every condition applies. Open a result or show the whole selection.'
              : 'All games are here. Add a player, event or position to narrow them down.',
          style: AppTextStyles.caption,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _computing
              ? const Center(child: CircularProgressIndicator())
              : _invalid || _boardDirty
              ? const SizedBox.shrink()
              : _computeError != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_computeError!, style: AppTextStyles.body),
                      TextButton(
                        onPressed: () {
                          if (!mounted) return;
                          _scheduledConfig = null;
                          _onFiltersChanged();
                        },
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                )
              : _matchingIndices.isEmpty
              ? const Center(
                  child: Text(
                    'No games yet. Try a shorter name, remove a row,\nor clear the position to broaden your search.',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.muted,
                  ),
                )
              : LinesPreviewPanel(
                  allGames: widget.allGames,
                  matchedIndices: _matchingIndices,
                  showSearch: false,
                  onGameTapped: widget.onOpenGame == null
                      ? null
                      : (index) {
                          if (!mounted || !_canApply) return;
                          widget.onOpenGame!(
                            _matchingIndices,
                            _filters.buildConfig(),
                            index,
                          );
                        },
                ),
        ),
      ],
    );
  }

  Widget _buildFooter() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: AppColors.divider)),
    ),
    child: OverflowBar(
      alignment: MainAxisAlignment.spaceBetween,
      spacing: 12,
      overflowSpacing: 8,
      children: [
        TextButton(onPressed: _reset, child: const Text('Clear filters')),
        Text(
          _boardDirty
              ? 'Board setup has unapplied changes'
              : 'Your draft stays here when you switch tabs.',
          style: AppTextStyles.caption,
        ),
        FilledButton(
          key: const ValueKey('apply-game-filters'),
          onPressed: _canApply && _matchingIndices.isNotEmpty
              ? () {
                  if (!mounted) return;
                  widget.onApply(_matchingIndices, _filters.buildConfig());
                }
              : null,
          child: Text(
            _invalid
                ? 'Check filters'
                : _computing
                ? 'Finding games…'
                : 'Show ${_matchingIndices.length} game${_matchingIndices.length == 1 ? '' : 's'}',
          ),
        ),
      ],
    ),
  );
}
