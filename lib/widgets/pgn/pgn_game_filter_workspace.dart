/// A persistent collection search beside the board: editable conditions, position
/// setup and live results. The host owns tab navigation and applying the draft.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/board_editor_controller.dart';
import '../../core/slice_filter_controller.dart';
import '../../models/pgn_filter_models.dart';
import '../../models/pgn_game_entry.dart';
import '../../services/pgn_parsing_service.dart' as pgn;
import '../../theme/app_text_styles.dart';
import '../../theme/app_colors.dart';
import '../board_editor/board_editor_panel.dart';
import 'pgn_tree_games_list.dart';
import '../common/choice_field.dart';
import '../opening_picker_dialog.dart';
import '../slice/header_filters.dart';
import '../slice/eco_filter_chips.dart';
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
    this.collectionPlayer,
    this.fenIndex,
  });

  final List<GameRecord> allGames;
  final String currentFen;
  final String? collectionName;
  final String? collectionPlayer;
  final SliceApplyCallback onApply;
  final void Function(List<int> indices, SliceConfig config, int gameIndex)?
  onOpenGame;
  final SliceConfig? initialConfig;
  final Map<String, List<int>>? fenIndex;

  @override
  State<PgnGameFilterWorkspace> createState() => _PgnGameFilterWorkspaceState();
}

class _PgnGameFilterWorkspaceState extends State<PgnGameFilterWorkspace> {
  late SliceFilterController _filters;
  late String _initialConfigJson;
  BoardEditorController? _board;
  TextEditingController? _boardInput;
  String? _boardBaseline;
  bool _boardDirty = false;
  List<int> _matchingIndices = [];
  bool _computing = false;
  String? _computeError;
  String? _scheduledConfig;
  final _filterScroll = ScrollController();
  Timer? _debounce;
  int _generation = 0;
  List<int>? _resultIndices;
  List<PgnGameEntry> _resultGames = [];

  List<PgnGameEntry> get _gamesForResults {
    if (!identical(_resultIndices, _matchingIndices)) {
      _resultIndices = _matchingIndices;
      _resultGames = [
        for (final i in _matchingIndices)
          PgnGameEntry(
            headers: widget.allGames[i].headers,
            pgnText: widget.allGames[i].pgnText,
          ),
      ];
    }
    return _resultGames;
  }

  bool get _hasFilters => !_filters.buildConfig().isEmpty;
  bool get _invalid =>
      _filters.hasInvalidPosition ||
      _filters.sequenceError != null ||
      _filters.headerRows.any((row) {
        if (row.hasMultiplePlayerNames) return true;
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

  Future<void> _chooseOpenings(int index) async {
    final row = _filters.headerRows[index];
    final selection = await showOpeningPicker(
      context,
      forFilters: true,
      initialEcoCodes: selectedEcoCodes(row.value, row.mode).toSet(),
    );
    if (!mounted || selection == null) return;
    index = _filters.headerRows.indexOf(row);
    if (index < 0 || row.field != 'ECO') return;
    if (selection.positionLine case final line?) {
      _filters.positionText.text = line.movetext.isEmpty
          ? line.position.fen
          : line.movetext;
    } else if (selection.lines.isNotEmpty) {
      final codes = selection.lines.map((line) => line.eco).toSet().toList()
        ..sort();
      _filters.setHeaderField(index, 'ECO');
      _filters.setHeaderMode(
        index,
        codes.length == 1 ? MatchMode.exact : MatchMode.regex,
      );
      _filters.headerRows[index].controller.text = ecoCodeExpression(codes);
      _filters.setHeaderValue(
        index,
        codes.length == 1
            ? codes.single
            : '^(${codes.map(RegExp.escape).join('|')})\$',
      );
    }
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
        additionalTargetFens: _filters.additionalPositionFens,
        matchAny: _filters.matchAny,
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
    if (_filters.headerRows.isEmpty) _filters.addHeaderRow(field: '');
  }

  void _reset() {
    if (!mounted) return;
    _closeBoard();
    _filters.reset();
    _removeEmptyRows();
  }

  void _editBoard(TextEditingController input) {
    if (!mounted || _board != null) return;
    _boardInput = input;
    final editor = BoardEditorController(
      initialFen: parsePositionInput(input.text).fen ?? widget.currentFen,
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
      _boardInput = null;
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
    color: AppColors.surfaceElevated,
    child: LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * .55),
            child: Scrollbar(
              controller: _filterScroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _filterScroll,
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
                child: _buildFilters(context),
              ),
            ),
          ),
          Expanded(
            child: _board == null
                ? _buildResults(context)
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(height: 660, child: _buildResults(context)),
                  ),
          ),
          _buildFooter(context),
        ],
      ),
    ),
  );

  Widget _buildFilters(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            'Combine',
            style: AppTextStyles.forTheme(context, AppTextStyles.caption),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 90,
            child: ChoiceField<bool>(
              key: const ValueKey('filter-logic'),
              value: _filters.matchAny,
              compact: true,
              style: AppTextStyles.forTheme(context, AppTextStyles.caption),
              items: const [
                ChoiceItem(value: false, label: 'AND'),
                ChoiceItem(value: true, label: 'OR'),
              ],
              onChanged: (value) {
                if (!mounted) return;
                _filters.setMatchAny(value);
              },
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      HeaderFilters(
        controller: _filters,
        games: widget.allGames,
        simple: true,
        onBrowseEco: _board == null ? _chooseOpenings : null,
      ),
      const SizedBox(height: 12),
      ExpansionTile(
        key: ValueKey(('position-filter-section', _filters)),
        tilePadding: EdgeInsets.zero,
        dense: true,
        initiallyExpanded:
            _filters.hasPositionFilter ||
            _filters.additionalPositions.isNotEmpty,
        title: Text(
          'Positions',
          style: AppTextStyles.forTheme(
            context,
            _filters.hasPositionFilter
                ? AppTextStyles.body
                : AppTextStyles.caption,
          ),
        ),
        children: [
          _positionRow(_filters.positionText, first: true),
          for (final input in _filters.additionalPositions) _positionRow(input),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('add-position'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
                minimumSize: const Size(120, 40),
                textStyle: AppTextStyles.muted,
              ),
              onPressed: _board != null
                  ? null
                  : () {
                      if (!mounted) return;
                      _filters.addPosition();
                    },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add position'),
            ),
          ),
        ],
      ),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        dense: true,
        title: Text(
          'Move sequence',
          style: AppTextStyles.forTheme(context, AppTextStyles.caption),
        ),
        initiallyExpanded: _filters.hasSequenceFilter,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SequenceFilter(controller: _filters),
          ),
        ],
      ),
    ],
  );

  Widget _positionRow(TextEditingController input, {bool first = false}) =>
      Padding(
        key: ObjectKey(input),
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IgnorePointer(
              ignoring: _board != null,
              child: PositionFilter(
                controller: _filters,
                input: input,
                showTitle: false,
              ),
            ),
            ChoiceField<String>(
              key: first ? const ValueKey('position-source') : null,
              value: null,
              hint: 'Choose position…',
              compact: true,
              enabled: _board == null,
              style: AppTextStyles.forTheme(context, AppTextStyles.caption),
              items: [
                const ChoiceItem(
                  value: 'current',
                  label: 'Use current position',
                ),
                const ChoiceItem(value: 'setup', label: 'Set up a board'),
                if (!first)
                  const ChoiceItem(value: 'remove', label: 'Remove position'),
              ],
              onChanged: (source) {
                if (!mounted) return;
                switch (source) {
                  case 'current':
                    input.text = widget.currentFen;
                  case 'setup':
                    _editBoard(input);
                  case 'remove':
                    _filters.removePosition(input);
                }
              },
            ),
          ],
        ),
      );

  Widget _buildResults(BuildContext context) {
    if (_board case final editor?) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Set up your position',
                  style: AppTextStyles.forTheme(
                    context,
                    AppTextStyles.bodyStrong,
                  ),
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
                    _boardInput!.text = position.fen;
                    _closeBoard();
                  },
            child: const Text('Use this position'),
          ),
        ],
      );
    }
    if (_computing) return const Center(child: CircularProgressIndicator());
    if (_invalid) {
      return Center(
        child: Text(
          'Check filters',
          style: AppTextStyles.forTheme(context, AppTextStyles.caption),
        ),
      );
    }
    if (_computeError != null) {
      return Center(
        child: TextButton(
          onPressed: () {
            if (!mounted) return;
            _scheduledConfig = null;
            _onFiltersChanged();
          },
          child: Text('$_computeError'),
        ),
      );
    }
    if (_matchingIndices.isEmpty) {
      return Center(
        child: Text(
          'No games match',
          style: AppTextStyles.forTheme(context, AppTextStyles.caption),
        ),
      );
    }
    return PgnTreeGamesList(
      games: _gamesForResults,
      currentFen: null,
      currentIndex: -1,
      initiallyShowMoves: false,
      subdued: true,
      toolbarLeading: Text(
        '${_matchingIndices.length} games',
        style: AppTextStyles.forTheme(context, AppTextStyles.caption),
      ),
      onGameSelected: (index) {
        if (!mounted || !_canApply || widget.onOpenGame == null) return;
        widget.onOpenGame!(
          _matchingIndices,
          _filters.buildConfig(),
          _matchingIndices[index],
        );
      },
    );
  }

  Widget _buildFooter(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border(
        top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: OverflowBar(
      alignment: MainAxisAlignment.spaceBetween,
      spacing: 12,
      overflowSpacing: 8,
      children: [
        TextButton(onPressed: _reset, child: const Text('Clear filters')),
        if (_boardDirty)
          Text(
            'Board setup has unapplied changes',
            style: AppTextStyles.forTheme(context, AppTextStyles.caption),
          ),
        FilledButton(
          key: const ValueKey('apply-game-filters'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: AppColors.surface,
          ),
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
                : 'Apply filter',
          ),
        ),
      ],
    ),
  );
}
