/// Games list widget - Flutter port of Python's games_list.py
/// Displays a list of games that contain a specific position
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/position_analysis.dart';
import '../theme/app_colors.dart';
import '../utils/app_messages.dart';
import 'common/list_search_field.dart';

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
  String _search = '';

  /// Indices into `widget.games` that survive the search box. Indices rather
  /// than games, so `_selectedIndex` keeps meaning the same row while the
  /// query changes underneath it.
  List<int> get _visibleIndices => [
    for (int i = 0; i < widget.games.length; i++)
      if (matchesSearch(_search, _haystack(widget.games[i]))) i,
  ];

  /// Everything a game can plausibly be looked up by: either player, the
  /// event, the date and the result.
  String _haystack(GameInfo g) =>
      '${g.white} ${g.black} ${g.event} ${g.date} ${g.result} ${g.site}';

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
            style: const TextStyle(color: AppColors.onSurfaceMuted),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final visible = _visibleIndices;
    final total = widget.games.length;
    final searching = _search.trim().isNotEmpty;

    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: const Border(bottom: BorderSide(color: AppColors.outline)),
          ),
          child: Text(
            searching
                ? '${visible.length} of $total games with this position'
                : '$total game${total == 1 ? '' : 's'} with this position',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: ListSearchField(
            hintText: 'Search by player, event or date',
            onChanged: (v) => setState(() => _search = v),
          ),
        ),

        // Games list
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    'No games match "$_search"',
                    style: const TextStyle(color: AppColors.onSurfaceMuted),
                  ),
                )
              : ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, row) {
                    final index = visible[row];
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
                                const Icon(
                                  Icons.bar_chart,
                                  size: 12,
                                  color: AppColors.starAccent,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  game.eloDisplay,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.starAccent,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ],
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
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.info,
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
