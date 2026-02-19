/// FEN list widget – left panel of the Player Analysis screen.
/// Displays positions with statistics, filtered by minimum games and sorted.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/position_analysis.dart';

class FenListWidget extends StatefulWidget {
  final PositionAnalysis analysis;
  final Function(String) onFenSelected;

  /// Whether the player is White in this analysis view.
  /// Determines the eval sort direction for "Bad Eval".
  final bool playerIsWhite;

  /// Whether engine eval data is available for the "Bad Eval" sort.
  final bool hasEvals;

  const FenListWidget({
    super.key,
    required this.analysis,
    required this.onFenSelected,
    this.playerIsWhite = true,
    this.hasEvals = false,
  });

  @override
  State<FenListWidget> createState() => _FenListWidgetState();
}

class _FenListWidgetState extends State<FenListWidget> {
  int _minGames = 3;
  String _sortBy = 'Lowest Win Rate';
  String? _selectedFen;

  late final TextEditingController _minGamesController;
  Timer? _minGamesErrorTimer;
  String? _minGamesError;

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
  }

  @override
  void dispose() {
    _minGamesController.dispose();
    _minGamesErrorTimer?.cancel();
    super.dispose();
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

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              const Text('Min games:', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              SizedBox(
                width: 72,
                child: TextField(
                  controller: _minGamesController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: const OutlineInputBorder(),
                    errorText: _minGamesError,
                    errorStyle: const TextStyle(fontSize: 10),
                  ),
                  onChanged: _validateMinGames,
                ),
              ),
            ],
          ),
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

  Widget _buildPositionsList() {
    final sortKey = _sortMap[_sortBy]!;
    final positions = widget.analysis.getSortedPositions(
      minGames: _minGames,
      sortBy: sortKey,
    );

    if (positions.isEmpty) {
      final isEvalSort = _sortBy == 'Bad Eval';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            isEvalSort
                ? 'No evaluated positions found.\nRun engine weakness analysis first.'
                : 'No positions found.\nTry lowering the minimum games filter.',
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
      final bad = widget.playerIsWhite
          ? (stats.evalCp! < -50)
          : (stats.evalCp! > 100);
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

    final evalTag = stats.hasEval
        ? '  [${stats.evalDisplay}]'
        : '';

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
        stats.fen.length > 40
            ? '${stats.fen.substring(0, 40)}...'
            : stats.fen,
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
