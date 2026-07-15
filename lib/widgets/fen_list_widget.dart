/// FEN list widget – left panel of the Player Analysis screen.
/// Displays positions with statistics, filtered by minimum games and sorted.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/opening_tree.dart';
import '../models/position_analysis.dart';
import '../utils/fen_utils.dart';

class FenListWidget extends StatefulWidget {
  final PositionAnalysis analysis;
  final Function(String) onFenSelected;

  /// Whether the player is White in this analysis view.
  /// Determines the eval sort direction for "Bad Eval".
  final bool playerIsWhite;

  /// Whether engine eval data is available for the "Bad Eval" sort.
  final bool hasEvals;

  /// Opening tree for the displayed colour — used to derive each position's
  /// move number (stored FENs are normalised to 4 fields, so the move counter
  /// is gone and the tree is the only source of depth).
  final OpeningTree? openingTree;

  const FenListWidget({
    super.key,
    required this.analysis,
    required this.onFenSelected,
    this.playerIsWhite = true,
    this.hasEvals = false,
    this.openingTree,
  });

  @override
  State<FenListWidget> createState() => _FenListWidgetState();
}

class _FenListWidgetState extends State<FenListWidget> {
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

  /// FEN → move number, memoised per tree (null = position not in tree).
  final Map<String, int?> _moveNumberCache = {};

  Map<String, String> get _sortMap => {
        if (widget.hasEvals) 'Bad Eval': _evalSortKey,
        'Lowest Win Rate': 'win_rate',
        'Highest Win Rate': 'win_rate_desc',
        'Most Games': 'games',
        'Most Losses': 'losses',
      };

  String get _evalSortKey =>
      widget.playerIsWhite ? 'eval_bad_white' : 'eval_bad_black';

  @override
  void initState() {
    super.initState();
    _minGamesController = TextEditingController(text: _minGames.toString());
    _minDepthController = TextEditingController(text: _minDepth.toString());
  }

  @override
  void didUpdateWidget(FenListWidget old) {
    super.didUpdateWidget(old);
    if (widget.hasEvals && !old.hasEvals && _sortBy == 'Lowest Win Rate') {
      setState(() => _sortBy = 'Bad Eval');
    }
    if (!_sortMap.containsKey(_sortBy)) {
      setState(() => _sortBy = _sortMap.keys.first);
    }
    if (!identical(widget.openingTree, old.openingTree)) {
      _moveNumberCache.clear();
      _selectedFen = null;
    }
  }

  @override
  void dispose() {
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
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          child: const Text(
            'Weak Positions',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            textAlign: TextAlign.center,
          ),
        ),
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
                      .map((key) => DropdownMenuItem(
                            value: key,
                            child:
                                Text(key, style: const TextStyle(fontSize: 12)),
                          ))
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
        const Divider(height: 1),
        Expanded(child: _buildPositionsList()),
      ],
    );
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
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: const OutlineInputBorder(),
                errorText: errorText,
                errorStyle: const TextStyle(fontSize: 10),
              ),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPositionsList() {
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

    if (positions.isEmpty) {
      final isEvalSort = _sortBy == 'Bad Eval';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            isEvalSort
                ? 'No evaluated positions found.\nRun "Analyze with Engine" first.'
                : 'No positions found.\nTry lowering the minimum games or depth filters.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: positions.length > 50 ? 50 : positions.length,
      itemBuilder: (context, index) {
        final stats = positions[index];
        return _buildPositionItem(index + 1, stats);
      },
    );
  }

  Widget _buildPositionItem(int rank, PositionStats stats) {
    final isSelected = _selectedFen == stats.fen;
    final showingEval = _sortBy == 'Bad Eval';

    Color? backgroundColor;
    if (showingEval && stats.hasEval) {
      final bad =
          widget.playerIsWhite ? (stats.evalCp! < -50) : (stats.evalCp! > 100);
      if (bad) {
        backgroundColor = Colors.red.withValues(alpha: 0.15);
      }
    } else {
      if (stats.winRate < 0.3) {
        backgroundColor = Colors.red.withValues(alpha: 0.2);
      } else if (stats.winRate < 0.4) {
        backgroundColor = Colors.yellow.withValues(alpha: 0.2);
      }
    }

    final evalTag = stats.hasEval ? '  [${stats.evalDisplay}]' : '';
    final moveNumber = _moveNumberForFen(stats.fen);
    final movePrefix = moveNumber == null
        ? ''
        : (moveNumber == 0 ? 'start · ' : 'move $moveNumber · ');

    return ListTile(
      selected: isSelected,
      selectedTileColor:
          Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
      tileColor: backgroundColor,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      title: Text(
        showingEval && stats.hasEval
            ? '#$rank: ${stats.evalDisplay}  '
                '(${stats.winRatePercent.toStringAsFixed(0)}% in ${stats.games}g)'
            : '#$rank: ${stats.winRatePercent.toStringAsFixed(1)}%$evalTag '
                '(${stats.wins}-${stats.losses}-${stats.draws} in ${stats.games})',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        movePrefix +
            (stats.fen.length > 40
                ? '${stats.fen.substring(0, 40)}...'
                : stats.fen),
        style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        setState(() => _selectedFen = stats.fen);
        widget.onFenSelected(stats.fen);
      },
    );
  }
}
