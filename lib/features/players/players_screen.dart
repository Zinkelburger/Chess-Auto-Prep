import 'dart:async';

import 'package:flutter/material.dart';

import '../../chess/players/player.dart';
import '../../ui/choice_dialog.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/row_actions.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'analysis_rows.dart' show ListMessage;
import 'group_dialog.dart';
import 'person_row.dart';
import 'player_dialogs.dart';
import 'players.dart';
import 'saved_games.dart';

/// The Players & prep page: everyone the user prepares for, or the groups
/// they are collected in for an event, as one dense list. A row has the two
/// things done with a person; the page has one filled button, which adds to
/// whatever is listed.
class PlayersScreen extends StatefulWidget {
  const PlayersScreen({
    super.key,
    required this.players,
    required this.saved,
    required this.onAnalyze,
    required this.onDeleteGames,
    required this.onStudy,
    required this.onSaved,
    required this.onLink,
    required this.onLinkedStudy,
    required this.onGroupStudy,
    required this.onTrainGroup,
    required this.onExport,
    required this.onCopy,
  });
  final Players players;
  final SavedGames saved;
  final ValueChanged<Player> onAnalyze;

  /// Deletes [person]'s downloads as the summary the user confirmed says;
  /// true when they were deleted.
  final Future<bool> Function(Player person, GamesSummary confirmed)
  onDeleteGames;
  final ValueChanged<Player> onStudy;
  final VoidCallback onSaved;
  final ValueChanged<Player> onLink;
  final void Function(String path, String? chapter) onLinkedStudy;
  final ValueChanged<PlayerGroup> onGroupStudy, onTrainGroup, onExport, onCopy;
  @override
  State<PlayersScreen> createState() => _PlayersScreenState();
}

class _PlayersScreenState extends State<PlayersScreen> {
  late final _search = TextEditingController(text: widget.players.query);
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Players get owner => widget.players;
  Future<void> _group({PlayerGroup? old}) async {
    final group = await editGroup(context, group: old);
    if (!mounted || group == null) return;
    if (await owner.saveGroup(group, expected: old) && mounted)
      owner.showGroup(group.id);
  }

  Future<void> _addMember(PlayerGroup group) async {
    final player = await showChoiceDialog<Player>(
      context,
      title: 'Add to ${group.name}',
      options: owner.players.where((p) => !group.contains(p.id)).toList(),
      label: (p) => p.name,
      hint: 'Search players',
      empty:
          'Everyone is already in this group. Add a new player from All players.',
    );
    if (player != null && mounted)
      await owner.saveGroup(group.member(player.id), expected: group);
  }

  Future<void> _remove(Player player) async {
    final group = owner.group;
    if (group != null) {
      if (!await confirmAction(
            context,
            title: 'Remove from ${group.name}?',
            message: 'Saved games and studies stay on disk.',
            confirm: 'Remove',
          ) ||
          !mounted)
        return;
      await owner.saveGroup(
        group.member(player.id, remove: true),
        expected: group,
      );
      return;
    }
    final saved = await widget.saved.current(player);
    if (!mounted) return;
    final answer = await removePlayer(context, player, saved: saved);
    if (answer == null || !mounted) return;
    // The owners outlive this screen: the removal the user chose goes ahead,
    // but a person whose downloads could not go stays, so they are not left
    // behind with nobody to delete them.
    if (answer == Removal.withGames &&
        !await widget.onDeleteGames(player, saved!)) {
      return;
    }
    await owner.remove(player);
  }

  Future<void> _deleteGames(Player player) async {
    final saved = await widget.saved.current(player);
    if (saved == null || saved.deletable == 0 || !mounted) return;
    final deleted = saved.deletable;
    if (await confirmAction(
          context,
          title: 'Delete ${player.name}’s saved games?',
          message: [
            'Moves $deleted downloaded ${deleted == 1 ? 'game' : 'games'} to '
                'the recovery folder and deletes their analysis. Linked PGN '
                'files stay.',
            if (saved.kept.isNotEmpty) keptLine(saved.kept),
          ].join(' '),
          confirm: 'Delete games',
        ) &&
        mounted)
      await widget.onDeleteGames(player, saved);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([owner, widget.saved]),
    builder: (context, _) {
      final group = owner.group;
      final groups = owner.showingGroups && group == null;
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: playersPageWidth),
          child: Padding(
            padding: const EdgeInsets.all(Space.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                group == null ? _viewSwitch() : _groupHeading(group),
                const SizedBox(height: Space.m),
                _toolbar(group, groups),
                _Notices(players: owner),
                Expanded(child: groups ? _groups() : _people()),
              ],
            ),
          ),
        ),
      );
    },
  );

  /// Everyone, or the groups people are collected in for an event.
  Widget _viewSwitch() => Align(
    alignment: Alignment.centerLeft,
    child: SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: false, label: Text('All players')),
        ButtonSegment(value: true, label: Text('Groups')),
      ],
      selected: {owner.showingGroups},
      showSelectedIcon: false,
      onSelectionChanged: (v) {
        if (!mounted) return;
        _search.clear();
        owner.showGroups(v.single);
      },
    ),
  );

  /// The way back to the groups, then the group's name and what is known of
  /// the event: `2026-10-10 · 5 rounds · 18 players · 5 prepared`.
  Widget _groupHeading(PlayerGroup group) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        TextButton.icon(
          onPressed: () {
            _search.clear();
            owner.showGroup(null);
          },
          icon: const Icon(Icons.arrow_back, size: IconSize.action),
          label: const Text('Groups'),
        ),
        const SizedBox(width: Space.s),
        Flexible(
          child: Text(
            group.name,
            style: text.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: Space.m),
        Flexible(
          child: Text(
            groupLine(group),
            style: text.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// The search, the one filled button — adding to whatever is listed — and
  /// the few things done to the list as a whole. The rest is behind `⋯`.
  Widget _toolbar(PlayerGroup? group, bool groups) {
    final blocked = owner.busy || owner.needsRetry;
    return Wrap(
      spacing: Space.s,
      runSpacing: Space.s,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: playersSearchWidth,
          child: SearchField(
            controller: _search,
            hint: groups ? 'Search groups' : 'Search name, ID or account',
            onChanged: owner.search,
          ),
        ),
        FilledButton(
          onPressed: blocked
              ? null
              : groups
              ? () => _group()
              : group != null
              ? () => _addMember(group)
              : () => editPlayer(context, owner),
          child: Text(
            groups
                ? 'New group'
                : group != null
                ? 'Add players'
                : 'Add player',
          ),
        ),
        if (!groups)
          OutlinedButton(
            onPressed: blocked ? null : () => importPlayers(context, owner),
            child: const Text('Paste players'),
          ),
        if (group != null) ...[
          TextButton(
            onPressed: () => widget.onGroupStudy(group),
            child: const Text('Open group study'),
          ),
          TextButton(
            onPressed: () => widget.onTrainGroup(group),
            child: const Text('Train group study'),
          ),
        ],
        _more(group),
      ],
    );
  }

  /// What is done seldom: the group's own entries first, then the
  /// directory's.
  Widget _more(PlayerGroup? group) => RowActions(
    tooltip: 'More actions',
    children: [
      if (group != null) ...[
        MenuItemButton(
          onPressed: owner.busy ? null : () => _group(old: group),
          child: const Text('Edit group…'),
        ),
        MenuItemButton(
          onPressed: () => widget.onCopy(group),
          child: const Text('Copy prep sheet'),
        ),
        MenuItemButton(
          onPressed: () => widget.onExport(group),
          child: const Text('Export prep sheet…'),
        ),
        if (group.fields['study'] case final String study when study.isNotEmpty)
          MenuItemButton(
            onPressed: owner.busy ? null : () => owner.unlinkGroupStudy(group),
            child: const Text('Unlink group study'),
          ),
      ],
      MenuItemButton(
        onPressed: owner.busy ? null : widget.onSaved,
        child: const Text('Add saved players'),
      ),
      // Only where there is a rating service to ask.
      if (owner.lookupRating != null)
        MenuItemButton(
          onPressed: owner.lookingUp ? null : owner.updateRatings,
          child: const Text('Update US Chess ratings'),
        ),
      MenuItemButton(
        onPressed: owner.busy ? null : owner.load,
        child: const Text('Reload players and groups'),
      ),
    ],
  );

  Widget _groups() {
    final groups = owner.groups
        .where((g) => g.name.toLowerCase().contains(owner.query.toLowerCase()))
        .toList();
    if (groups.isEmpty) {
      return ListMessage(
        owner.query.isNotEmpty
            ? 'No groups match this search.'
            : 'No groups yet. A group collects the players of an event, with '
                  'a prep sheet and a study for the whole field.',
      );
    }
    return ListView.separated(
      itemCount: groups.length,
      separatorBuilder: (context, _) => const Divider(height: 1),
      itemBuilder: (context, i) => _GroupRow(
        group: groups[i],
        busy: owner.busy,
        onOpen: () {
          _search.clear();
          owner.showGroup(groups[i].id);
        },
        onEdit: () => _group(old: groups[i]),
        onRemove: () => _removeGroup(groups[i]),
      ),
    );
  }

  Future<void> _removeGroup(PlayerGroup group) async {
    if (await confirmAction(
          context,
          title: 'Remove ${group.name}?',
          message: 'Players, saved games and studies stay in your library.',
          confirm: 'Remove',
        ) &&
        mounted) {
      await owner.removeGroup(group);
    }
  }

  Widget _people() {
    final players = owner.visible;
    if (players.isEmpty) {
      return ListMessage(
        owner.query.isNotEmpty
            ? 'No players match this search.'
            : owner.group == null
            ? 'No players yet. Add a player with an online account, or paste '
                  'a player list.'
            : 'Nobody in this group yet. Add players from your directory, or '
                  'paste the event’s player list.',
      );
    }
    return ListView.separated(
      itemCount: players.length,
      separatorBuilder: (context, _) => const Divider(height: 1),
      itemBuilder: (context, i) => PersonRow(
        player: players[i],
        group: owner.group,
        owner: owner,
        saved: widget.saved,
        onAnalyze: widget.onAnalyze,
        onStudy: widget.onStudy,
        onLink: widget.onLink,
        onLinkedStudy: widget.onLinkedStudy,
        onRemove: _remove,
        onDeleteGames: _deleteGames,
      ),
    );
  }
}

/// `2026-10-10 · 5 rounds · 18 players · 5 prepared`: what is known of the
/// event, then how far the prep is.
String groupLine(PlayerGroup group) {
  final players = group.entries.length;
  final prepared = group.entries.where((e) => e['prepared'] == true).length;
  final rounds = group.fields['rounds'];
  return [
    if (group.fields['date'] case final String date when date.isNotEmpty) date,
    if (rounds is int) '$rounds ${rounds == 1 ? 'round' : 'rounds'}',
    '$players ${players == 1 ? 'player' : 'players'}',
    '$prepared prepared',
  ].join(' · ');
}

/// One group: its name over what is known of the event. Opens on a click.
class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.group,
    required this.busy,
    required this.onOpen,
    required this.onEdit,
    required this.onRemove,
  });

  final PlayerGroup group;
  final bool busy;
  final VoidCallback onOpen, onEdit, onRemove;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onOpen,
      child: SizedBox(
        height: puzzleRowHeight,
        child: Row(
          children: [
            const SizedBox(width: Space.m),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.name,
                    style: text.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    groupLine(group),
                    style: text.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            RowActions(
              tooltip: 'Group actions',
              children: [
                MenuItemButton(
                  onPressed: busy ? null : onEdit,
                  child: const Text('Edit group…'),
                ),
                MenuItemButton(
                  onPressed: busy ? null : onRemove,
                  child: const Text('Remove group…'),
                ),
              ],
            ),
            const SizedBox(width: Space.s),
          ],
        ),
      ),
    );
  }
}

/// Under the toolbar: the line that says the directory is being read or
/// written, a rating lookup with the way to stop it, files that could not
/// be read, and a failed save with what can be done about it. The line for
/// the bar is always there, so the list does not move when it shows.
class _Notices extends StatelessWidget {
  const _Notices({required this.players});

  final Players players;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wrong = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.error,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.s),
          child: SizedBox(
            height: progressLineHeight,
            child: players.busy ? const LinearProgressIndicator() : null,
          ),
        ),
        if (players.lookupStatus case final status?)
          Row(
            children: [
              Flexible(child: Text(status, style: theme.textTheme.bodySmall)),
              if (players.lookingUp)
                TextButton(
                  onPressed: players.stopLookup,
                  child: const Text('Stop'),
                ),
            ],
          ),
        for (final warning in players.warnings) Text(warning, style: wrong),
        if (players.error case final error?)
          Wrap(
            spacing: Space.s,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(error, style: wrong),
              if (players.needsRetry) ...[
                TextButton(
                  onPressed: players.busy ? null : players.retry,
                  child: const Text('Retry save'),
                ),
                TextButton(
                  onPressed: players.busy ? null : players.discardFailed,
                  child: const Text('Discard failed edit and reload'),
                ),
              ] else
                TextButton(
                  onPressed: players.load,
                  child: const Text('Try again'),
                ),
            ],
          ),
      ],
    );
  }
}
