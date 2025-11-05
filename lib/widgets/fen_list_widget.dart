/// FEN list widget - Flutter port of Python's fen_list.py
/// Displays a list of FENs with statistics, allows filtering and sorting

import 'package:flutter/material.dart';
import '../models/position_analysis.dart';

class FenListWidget extends StatefulWidget {
  final PositionAnalysis analysis;
  final Function(String) onFenSelected;

  const FenListWidget({
    super.key,
    required this.analysis,
    required this.onFenSelected,
  });

  @override
  State<FenListWidget> createState() => _FenListWidgetState();
}

class _FenListWidgetState extends State<FenListWidget> {
  int _minGames = 3;
  String _sortBy = 'Lowest Win Rate';
  String? _selectedFen;

  final Map<String, String> _sortMap = {
    'Lowest Win Rate': 'win_rate',
    'Most Games': 'games',
    'Most Losses': 'losses',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(8),
          child: const Text(
            'Position Analysis',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
            textAlign: TextAlign.center,
          ),
        ),

        // Filters
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              const Text('Min games:', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<int>(
                  value: _minGames,
                  isExpanded: true,
                  items: [1, 2, 3, 4, 5, 10, 15, 20]
                      .map((value) => DropdownMenuItem(
                            value: value,
                            child: Text(value.toString()),
                          ))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _minGames = value);
                    }
                  },
                ),
              ),
            ],
          ),
        ),

        // Sort by
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
                            child: Text(key, style: const TextStyle(fontSize: 12)),
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

        // List
        Expanded(
          child: _buildPositionsList(),
        ),
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
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'No positions found.\nTry lowering the minimum games filter.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
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

    // Color code by win rate
    Color? backgroundColor;
    if (stats.winRate < 0.3) {
      backgroundColor = Colors.red.withOpacity(0.2);
    } else if (stats.winRate < 0.4) {
      backgroundColor = Colors.yellow.withOpacity(0.2);
    }

    return ListTile(
      selected: isSelected,
      selectedTileColor: Theme.of(context).colorScheme.primary.withOpacity(0.3),
      tileColor: backgroundColor,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      title: Text(
        '#$rank: ${stats.winRatePercent.toStringAsFixed(1)}% '
        '(${stats.wins}-${stats.losses}-${stats.draws} in ${stats.games})',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        stats.fen.length > 40 ? '${stats.fen.substring(0, 40)}...' : stats.fen,
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
