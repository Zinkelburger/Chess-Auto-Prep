/// FEN list widget – left panel of the Player Analysis screen.
/// Displays positions with statistics, filtered by minimum games and sorted.
/// Selection steps through the ranked list via the Prev/Next header buttons
/// or a [ListNavController] (previous/next forwarded by the host screen).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/opening_tree.dart';
import '../models/position_analysis.dart';
import '../theme/app_colors.dart';
import '../utils/app_messages.dart';
import 'copy_button.dart';
import '../utils/fen_utils.dart';
import 'common/list_nav.dart';

class FenListWidget extends StatefulWidget {
  final PositionAnalysis analysis;
  final Function(String) onFenSelected;

  /// Whether the player is White in this analysis view.
  /// Determines the eval sort direction for "Bad Eval" / "Good Eval".
  final bool playerIsWhite;

  /// Whether engine eval data is available for the eval sorts.
  final bool hasEvals;

  /// Opening tree for the displayed colour — used to derive each position's
  /// move number (stored FENs are normalised to 4 fields, so the move counter
  /// is gone and the tree is the only source of depth).
  final OpeningTree? openingTree;

  /// Lets the host screen step the selection (keyboard shortcuts).
  final ListNavController? navController;

  const FenListWidget({
    super.key,
    required this.analysis,
    required this.onFenSelected,
    this.playerIsWhite = true,
    this.hasEvals = false,
    this.openingTree,
    this.navController,
  });

  @override
  State<FenListWidget> createState() => _FenListWidgetState();
}

class _FenListWidgetState extends State<FenListWidget>
    implements ListNavTarget {
  int _minGames = 3;
  int _minDepth = 1;
  String _sortBy = 'Lowest Win Rate';
  String? _selectedFen;

  late final TextEditingController _minGamesController;
  Timer? _minGamesErrorTimer;
  String? _minGamesError;

  late final TextEditingController _minDepthController;
  Timer? _minDepthErrorTimer;
  String? _minDepthError;

  /// Fixed row height (ListView.itemExtent) so keyboard stepping can compute
  /// scroll offsets exactly instead of estimating.
  static const double _itemExtent = 56.0;
  final ScrollController _scrollController = ScrollController();

  /// FEN → move number, memoised per tree (null = position not in tree).
  final Map<String, int?> _moveNumberCache = {};

  /// FEN → reach estimate, memoised per tree (null = position not in tree).
  final Map<String, ReachEstimate?> _reachCache = {};

  Map<String, String> get _sortMap => {
    if (widget.hasEvals) 'Bad Eval': _badEvalSortKey,
    if (widget.hasEvals) 'Good Eval': _goodEvalSortKey,
    'Lowest Win Rate': 'win_rate',
    'Highest Win Rate': 'win_rate_desc',
    'Most Games': 'games',
    'Most Wins': 'wins',
    'Most Losses': 'losses',
  };

  String get _badEvalSortKey =>
      widget.playerIsWhite ? 'eval_bad_white' : 'eval_bad_black';

  String get _goodEvalSortKey =>
      widget.playerIsWhite ? 'eval_good_white' : 'eval_good_black';

  bool get _isEvalSort => _sortBy == 'Bad Eval' || _sortBy == 'Good Eval';

  @override
  void initState() {
    super.initState();
    widget.navController?.attach(this);
    _minGamesController = TextEditingController(text: _minGames.toString());
    _minDepthController = TextEditingController(text: _minDepth.toString());
  }

  @override
  void didUpdateWidget(FenListWidget old) {
    super.didUpdateWidget(old);
    if (!identical(widget.navController, old.navController)) {
      old.navController?.detach(this);
      widget.navController?.attach(this);
    }
    if (widget.hasEvals && !old.hasEvals && _sortBy == 'Lowest Win Rate') {
      setState(() => _sortBy = 'Bad Eval');
    }
    if (!_sortMap.containsKey(_sortBy)) {
      setState(() => _sortBy = _sortMap.keys.first);
    }
    if (!identical(widget.openingTree, old.openingTree) ||
        widget.playerIsWhite != old.playerIsWhite) {
      _moveNumberCache.clear();
      _reachCache.clear();
      _selectedFen = null;
    }
  }

  @override
  void dispose() {
    widget.navController?.detach(this);
    _scrollController.dispose();
    _minGamesController.dispose();
    _minGamesErrorTimer?.cancel();
    _minDepthController.dispose();
    _minDepthErrorTimer?.cancel();
    super.dispose();
  }

  /// Move number of the position, counted by move pairs: the positions after
  /// 1.e4 and after 1...c5 are both "move 1", and the starting position is 0.
  /// Null if the position isn't in the opening tree. Transpositions use the
  /// shallowest occurrence.
  int? _moveNumberForFen(String fen) {
    return _moveNumberCache.putIfAbsent(fen, () {
      final nodes = widget.openingTree?.fenToNodes[normalizeFen(fen)];
      if (nodes == null || nodes.isEmpty) return null;
      int minPly = nodes.first.getMovePath().length;
      for (final node in nodes.skip(1)) {
        final ply = node.getMovePath().length;
        if (ply < minPly) minPly = ply;
      }
      return (minPly + 1) ~/ 2;
    });
  }

  /// How likely the analyzed player is to steer the game into this position
  /// (summed across transpositions). Null if the position isn't in the tree.
  ReachEstimate? _reachForFen(String fen) {
    return _reachCache.putIfAbsent(fen, () {
      final nodes = widget.openingTree?.fenToNodes[normalizeFen(fen)];
      if (nodes == null || nodes.isEmpty) return null;
      return PositionGroup(
        nodes,
      ).reachEstimate(protagonistIsWhite: widget.playerIsWhite);
    });
  }

  void _validateMinGames(String value) {
    final v = int.tryParse(value);
    String? error;
    if (v == null) {
      error = 'Must be a number';
    } else if (v < 1) {
      error = 'Minimum is 1';
    }

    _minGamesErrorTimer?.cancel();

    setState(() {
      if (error == null) {
        _minGamesError = null;
        _minGames = v!;
      }
    });

    if (error != null) {
      _minGamesErrorTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _minGamesError = error);
      });
    }
  }

  void _validateMinDepth(String value) {
    final v = int.tryParse(value);
    String? error;
    if (v == null) {
      error = 'Must be a number';
    } else if (v < 1) {
      error = 'Minimum is 1';
    }

    _minDepthErrorTimer?.cancel();

    setState(() {
      if (error == null) {
        _minDepthError = null;
        _minDepth = v!;
      }
    });

    if (error != null) {
      _minDepthErrorTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _minDepthError = error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final positions = _visiblePositions();
    return Column(
      children: [
        _buildFilterRow(
          label: 'Min games:',
          controller: _minGamesController,
          errorText: _minGamesError,
          onChanged: _validateMinGames,
        ),
        _buildFilterRow(
          label: 'Min depth (move #):',
          controller: _minDepthController,
          errorText: _minDepthError,
          onChanged: _validateMinDepth,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              const Text('Sort by:', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<String>(
                  value: _sortBy,
                  isExpanded: true,
                  items: _sortMap.keys
                      .map(
                        (key) => DropdownMenuItem(
                          value: key,
                          child: Text(
                            key,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _sortBy = value);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        _buildNavRow(positions),
        const Divider(height: 1),
        Expanded(child: _buildPositionsList(positions)),
      ],
    );
  }

  /// Previous/Next stepping over the displayed list with a "k of n" readout.
  /// The keyboard equivalents come in from the host screen through
  /// [ListNavController].
  Widget _buildNavRow(List<PositionStats> positions) {
    final selectedIndex = positions.indexWhere((s) => s.fen == _selectedFen);
    return ListNavRow(
      itemLabel: 'position',
      canPrevious: selectedIndex > 0,
      canNext: positions.isNotEmpty && selectedIndex < positions.length - 1,
      onPrevious: stepPrevious,
      onNext: stepNext,
      counterText: selectedIndex >= 0
          ? '${selectedIndex + 1} of ${positions.length}'
          : '${positions.length} position${positions.length == 1 ? '' : 's'}',
    );
  }

  @override
  void stepNext() => _step(1);

  @override
  void stepPrevious() => _step(-1);

  /// Move the selection [delta] rows. With no current selection (or the
  /// selected position filtered out of view), any step selects the top row.
  void _step(int delta) {
    final positions = _visiblePositions();
    if (positions.isEmpty) return;
    final current = positions.indexWhere((s) => s.fen == _selectedFen);
    final target = current < 0
        ? 0
        : (current + delta).clamp(0, positions.length - 1);
    if (target == current) return;
    final stats = positions[target];
    setState(() => _selectedFen = stats.fen);
    widget.onFenSelected(stats.fen);
    ensureRowVisible(_scrollController, target, _itemExtent);
  }

  Widget _buildFilterRow({
    required String label,
    required TextEditingController controller,
    required String? errorText,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                border: const OutlineInputBorder(),
                errorText: errorText,
                errorStyle: const TextStyle(fontSize: 12),
              ),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  /// The list exactly as displayed — sorted, filtered, capped at 50 rows —
  /// so stepping and the "k of n" counter can never disagree with the view.
  List<PositionStats> _visiblePositions() {
    final sortKey = _sortMap[_sortBy]!;
    var positions = widget.analysis.getSortedPositions(
      minGames: _minGames,
      sortBy: sortKey,
    );

    // Depth filter: keep positions reached at or after the chosen move
    // number. Positions the tree doesn't know about are kept.
    if (_minDepth > 1) {
      positions = positions.where((stats) {
        final move = _moveNumberForFen(stats.fen);
        return move == null || move >= _minDepth;
      }).toList();
    }

    return positions.length > 50 ? positions.sublist(0, 50) : positions;
  }

  Widget _buildPositionsList(List<PositionStats> positions) {
    if (positions.isEmpty) {
      final isEvalSort = _isEvalSort;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            isEvalSort
                ? 'No evaluated positions found.\nRun "Analyze with Engine" first.'
                : 'No positions found.\nTry lowering the minimum games or depth filters.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.onSurfaceMuted),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      itemCount: positions.length,
      itemExtent: _itemExtent,
      itemBuilder: (context, index) {
        final stats = positions[index];
        return _buildPositionItem(index + 1, stats);
      },
    );
  }

  String _gamesLabel(int games) => '$games game${games == 1 ? '' : 's'}';

  Widget _buildPositionItem(int rank, PositionStats stats) {
    final isSelected = _selectedFen == stats.fen;
    final showingEval = _isEvalSort;

    Color? backgroundColor;
    if (showingEval && stats.hasEval) {
      final bad = widget.playerIsWhite
          ? (stats.evalCp! < -50)
          : (stats.evalCp! > 100);
      final good = widget.playerIsWhite
          ? (stats.evalCp! > 100)
          : (stats.evalCp! < -50);
      if (bad) {
        backgroundColor = AppColors.dangerTint;
      } else if (good) {
        backgroundColor = AppColors.successTint;
      }
    } else {
      if (stats.winRate < 0.3) {
        backgroundColor = AppColors.dangerTint;
      } else if (stats.winRate < 0.4) {
        backgroundColor = AppColors.warningTint;
      }
    }

    final evalTag = stats.hasEval ? '  [${stats.evalDisplay}]' : '';
    final moveNumber = _moveNumberForFen(stats.fen);
    final movePrefix = moveNumber == null
        ? ''
        : (moveNumber == 0 ? 'start · ' : 'move $moveNumber · ');

    // Reach stats are more useful at a glance than the raw FEN (which is a
    // click away via the board's Copy FEN button); fall back to the FEN for
    // positions the tree doesn't know.
    final reach = _reachForFen(stats.fen);
    final subtitle = reach != null
        ? '$movePrefix${reach.percentLabel}% reached · '
              '${reach.decisionPoints} branch '
              'point${reach.decisionPoints == 1 ? '' : 's'}'
        : movePrefix +
              (stats.fen.length > 40
                  ? '${stats.fen.substring(0, 40)}...'
                  : stats.fen);

    return ListTile(
      selected: isSelected,
      selectedTileColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.3),
      tileColor: backgroundColor,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      title: Text(
        showingEval && stats.hasEval
            ? '#$rank: ${stats.evalDisplay}  '
                  '(${stats.winRatePercent.toStringAsFixed(0)}% in '
                  '${_gamesLabel(stats.games)})'
            : '#$rank: ${stats.winRatePercent.toStringAsFixed(1)}%$evalTag '
                  '(${stats.wins}W-${stats.draws}D-${stats.losses}L in '
                  '${_gamesLabel(stats.games)})',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, fontFamily: 'SourceCodePro'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: SizedBox(
        width: 28,
        height: 28,
        child: CopyButton.icon(
          tooltip: 'Copy FEN',
          iconSize: 14,
          dense: true,
          foreground: AppColors.onSurfaceSoft,
          snackBarMessage: AppMessages.fenCopied,
          text: () => expandFen(stats.fen),
        ),
      ),
      onTap: () {
        setState(() => _selectedFen = stats.fen);
        widget.onFenSelected(stats.fen);
      },
    );
  }
}
