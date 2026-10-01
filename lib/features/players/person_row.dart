import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../chess/players/player.dart';
import '../../chess/tactics/game_ids.dart';
import '../../ui/check_row.dart';
import '../../ui/relative_time.dart';
import '../../ui/row_actions.dart';
import '../../ui/theme.dart';
import 'player_dialogs.dart';
import 'player_lookup.dart';
import 'players.dart';
import 'saved_games.dart';

/// One person in the directory or in a group: who they are and where their
/// games come from, how many games are saved, and the two things done with
/// a person — look at their games, write the prep. Everything else about
/// them is behind the row's `⋯`.
///
/// In a wide window the saved games sit in a column of their own, so the
/// counts of a whole field read down the page; in a narrow one they go
/// under the name.
class PersonRow extends StatelessWidget {
  const PersonRow({
    super.key,
    required this.player,
    required this.group,
    required this.owner,
    required this.saved,
    required this.onAnalyze,
    required this.onStudy,
    required this.onLink,
    required this.onLinkedStudy,
    required this.onRemove,
    required this.onDeleteGames,
  });

  final Player player;

  /// The group being shown, whose prepared ticks the row carries; null in
  /// the directory.
  final PlayerGroup? group;
  final Players owner;
  final SavedGames saved;
  final ValueChanged<Player> onAnalyze, onStudy, onLink, onRemove;
  final ValueChanged<Player> onDeleteGames;
  final void Function(String path, String? chapter) onLinkedStudy;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s),
    child: LayoutBuilder(
      builder: (context, box) => box.maxWidth >= personRowBreak
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _who(context)),
                const SizedBox(width: Space.l),
                SizedBox(width: personGamesWidth, child: _games(context)),
                _actions(context),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [_who(context), _games(context), _actions(context)],
            ),
    ),
  );

  /// The name with the rating beside it, the accounts and the federation
  /// number, the prep notes, the studies linked, and any account research.
  Widget _who(BuildContext context) {
    final theme = Theme.of(context);
    final rating = player.text('rating');
    final notes = player.text('notes');
    final links = _studyLinks(theme);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                player.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (rating.isNotEmpty) ...[
              const SizedBox(width: Space.s),
              Text(
                rating,
                style: monoText.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        Text(
          [
            if (player.accounts.isEmpty) 'No online accounts',
            // A site once, with every username there.
            for (final site in GameSite.values)
              if (_usernames(site) case final names when names.isNotEmpty)
                '${site.label} $names',
            if (player.text('uscf_id').isNotEmpty)
              'US Chess ${player.text('uscf_id')}',
          ].join(' · '),
          style: theme.textTheme.bodySmall,
        ),
        if (notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Text(
              notes,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (links.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Wrap(
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: links,
            ),
          ),
        PlayerLookup(player: player, owner: owner),
      ],
    );
  }

  String _usernames(GameSite site) => player.accounts
      .where((a) => a.site == site)
      .map((a) => a.username)
      .join(', ');

  /// How many games are saved and how fresh; in a group, whether the prep
  /// for this person is done.
  Widget _games(BuildContext context) {
    final group = this.group;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          savedLine(saved.of(player), player.files.length),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (group != null)
          CheckRow(
            label: 'Prepared',
            value: group.prepared(player.id),
            onChanged: owner.busy
                ? null
                : (on) => owner.saveGroup(
                    group.member(player.id, prepared: on),
                    expected: group,
                  ),
          ),
      ],
    );
  }

  Widget _actions(BuildContext context) {
    final prep = player.text('prep_file').isNotEmpty;
    final deletable = (saved.of(player)?.deletable ?? 0) > 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          onPressed: () => onAnalyze(player),
          child: const Text('Analyze games'),
        ),
        TextButton(
          onPressed: () => onStudy(player),
          child: Text(prep ? 'Open prep study' : 'New prep study'),
        ),
        RowActions(
          tooltip: 'Player actions',
          children: [
            MenuItemButton(
              onPressed: owner.busy
                  ? null
                  : () => editPlayer(context, owner, player: player),
              child: const Text('Edit player…'),
            ),
            MenuItemButton(
              onPressed: () => onLink(player),
              child: const Text('Link study…'),
            ),
            if (prep)
              MenuItemButton(
                onPressed: owner.busy ? null : () => owner.unlinkPrep(player),
                child: const Text('Unlink prep study'),
              ),
            if (deletable)
              MenuItemButton(
                onPressed: owner.busy || saved.deleting.contains(player.id)
                    ? null
                    : () => onDeleteGames(player),
                child: const Text('Delete saved games…'),
              ),
            MenuItemButton(
              onPressed: owner.busy ? null : () => onRemove(player),
              child: Text(
                group == null ? 'Remove player…' : 'Remove from group…',
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// The studies and chapters linked to the person, each a chip that opens
  /// it and can be taken off.
  List<Widget> _studyLinks(ThemeData theme) => [
    for (final link in player.fields['studies'] as List? ?? const [])
      if (link is Map && link['path'] is String)
        InputChip(
          label: Text(
            link['chapter'] as String? ??
                p.basenameWithoutExtension(link['path'] as String),
          ),
          labelStyle: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface,
          ),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: EdgeInsets.zero,
          labelPadding: const EdgeInsets.only(left: Space.s),
          deleteButtonTooltipMessage: 'Unlink study',
          onPressed: () =>
              onLinkedStudy(link['path'] as String, link['chapter'] as String?),
          onDeleted: owner.busy
              ? null
              : () => owner.save(
                  player.edited({
                    'studies': [
                      for (final other in player.fields['studies'] as List)
                        if (!identical(other, link)) other,
                    ],
                  }),
                  expected: player,
                ),
        ),
  ];
}

/// `412 saved games · 2 PGN files · downloaded 3d ago`; blank until counted,
/// so the row keeps its height when the count arrives.
String savedLine(GamesSummary? saved, int files) {
  if (saved == null) return '';
  final games = saved.downloaded + saved.linked;
  return [
    games == 0
        ? 'No saved games'
        : '$games saved ${games == 1 ? 'game' : 'games'}',
    if (files > 0) '$files PGN ${files == 1 ? 'file' : 'files'}',
    if (saved.fetched case final at?) 'downloaded ${relativeTime(at)}',
  ].join(' · ');
}
