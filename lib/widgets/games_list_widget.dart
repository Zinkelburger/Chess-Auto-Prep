/// Games list widget - Flutter port of Python's games_list.py
/// Displays a list of games that contain a specific position

import 'package:flutter/material.dart';
import '../models/position_analysis.dart';

class GamesListWidget extends StatefulWidget {
  final List<GameInfo> games;
  final String? currentFen;
  final Function(GameInfo)? onGameSelected;

  const GamesListWidget({
    super.key,
    required this.games,
    this.currentFen,
    this.onGameSelected,
  });

  @override
  State<GamesListWidget> createState() => _GamesListWidgetState();
}

class _GamesListWidgetState extends State<GamesListWidget> {
  int? _selectedIndex;

  @override
  void didUpdateWidget(GamesListWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset selection when games change
    if (widget.currentFen != oldWidget.currentFen) {
      _selectedIndex = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.games.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Select a position to see games',
            style: TextStyle(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: Colors.grey.shade700,
              ),
            ),
          ),
          child: Text(
            '${widget.games.length} game${widget.games.length == 1 ? '' : 's'} with this position',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
        ),

        // Games list
        Expanded(
          child: ListView.builder(
            itemCount: widget.games.length,
            itemBuilder: (context, index) {
              final game = widget.games[index];
              final isSelected = _selectedIndex == index;

              return ListTile(
                selected: isSelected,
                selectedTileColor:
                    Theme.of(context).colorScheme.primary.withOpacity(0.3),
                dense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                title: Text(
                  game.title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (game.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        game.subtitle,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                    if (game.site.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        game.site,
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.blue.shade300,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
                onTap: () {
                  setState(() => _selectedIndex = index);
                  if (widget.onGameSelected != null) {
                    widget.onGameSelected!(game);
                  }
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
