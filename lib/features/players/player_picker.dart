import 'package:flutter/material.dart';

import '../../chess/players/player.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'analysis_rows.dart';
import 'players.dart';

/// The Player analysis column before anyone is chosen: the saved players to
/// pick from, narrowed by a search, or the way to add the first one.
class PlayerPicker extends StatefulWidget {
  const PlayerPicker({
    super.key,
    required this.players,
    required this.onChoose,
    required this.onAdd,
    required this.onDirectory,
  });

  final Players players;
  final ValueChanged<Player> onChoose;
  final VoidCallback onAdd;

  /// Opens Players & prep, where people are edited and grouped.
  final VoidCallback onDirectory;

  @override
  State<PlayerPicker> createState() => _PlayerPickerState();
}

class _PlayerPickerState extends State<PlayerPicker> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _searched(String query) {
    if (mounted) setState(() => _query = query.trim().toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.players.players;
    final shown = [
      for (final player in all)
        if (player.search.contains(_query)) player,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.players.error case final error?)
          ListMessage(
            error,
            action: TextButton(
              onPressed: widget.players.load,
              child: const Text('Try again'),
            ),
          ),
        if (all.isEmpty)
          ListMessage(
            'Add the player you are preparing for, with their Lichess or '
            'Chess.com username or a PGN of their games.',
            action: FilledButton(
              onPressed: widget.onAdd,
              child: const Text('Add player'),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m, Space.s),
            child: SearchField(
              controller: _search,
              hint: 'Search players',
              onChanged: _searched,
            ),
          ),
          Expanded(
            child: shown.isEmpty
                ? ListMessage('Nobody matches "${_search.text.trim()}".')
                : ListView.builder(
                    itemCount: shown.length,
                    itemExtent: puzzleRowHeight,
                    itemBuilder: (context, at) => _PlayerRow(
                      player: shown[at],
                      onChoose: () => widget.onChoose(shown[at]),
                    ),
                  ),
          ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.xs),
            child: TextButton(
              onPressed: widget.onDirectory,
              child: const Text('Players & prep'),
            ),
          ),
        ),
      ],
    );
  }
}

/// One saved player: the name, and where their games come from.
class _PlayerRow extends StatelessWidget {
  const _PlayerRow({required this.player, required this.onChoose});

  final Player player;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final files = player.files.length;
    final sources = [
      for (final account in player.accounts)
        '${account.site.label} ${account.username}',
      if (files > 0) '$files PGN ${files == 1 ? 'file' : 'files'}',
    ];
    return InkWell(
      onTap: onChoose,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.m),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              player.name,
              style: theme.textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              sources.isEmpty ? 'No games linked yet' : sources.join(' · '),
              style: theme.textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
