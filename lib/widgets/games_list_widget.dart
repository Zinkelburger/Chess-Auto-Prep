/// Games list widget - Flutter port of Python's games_list.py
/// Displays a list of games that contain a specific position
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/position_analysis.dart';
import '../utils/app_messages.dart';

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

  Future<void> _openGameUrl(String url) async {
    final uri = Uri.tryParse(url);
    bool ok;
    try {
      // launchUrl throws (rather than returning false) on some platforms.
      ok = uri != null && await launchUrl(uri);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      showAppSnackBar(context, 'Could not open $url', isError: true);
    }
  }

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
      final message = widget.currentFen != null
          ? 'No games found in this position'
          : 'Select a position to see games';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            message,
            style: const TextStyle(color: Colors.grey),
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
            border: Border(bottom: BorderSide(color: Colors.grey.shade700)),
          ),
          child: Text(
            '${widget.games.length} game${widget.games.length == 1 ? '' : 's'} with this position',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
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
                selectedTileColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.3),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                trailing: game.gameUrl != null
                    ? IconButton(
                        icon: const Icon(Icons.open_in_new, size: 16),
                        tooltip: 'Open game in browser',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _openGameUrl(game.gameUrl!),
                      )
                    : null,
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
                    if (game.eloDisplay.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            Icons.bar_chart,
                            size: 12,
                            color: Colors.amber.shade300,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            game.eloDisplay,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.amber.shade300,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (game.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(game.subtitle, style: const TextStyle(fontSize: 11)),
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
