import 'player_lookup.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../ui/choice_dialog.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/search_field.dart';
import '../../ui/relative_time.dart';
import '../../ui/theme.dart';
import '../../chess/players/player.dart';
import 'player_dialogs.dart';
import 'group_dialog.dart';
import 'players.dart';
import 'saved_games.dart';

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
          constraints: const BoxConstraints(maxWidth: 1040),
          child: Padding(
            padding: const EdgeInsets.all(Space.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: Space.s,
                  runSpacing: Space.s,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (group != null)
                      TextButton.icon(
                        onPressed: () {
                          _search.clear();
                          owner.showGroup(null);
                        },
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Groups'),
                      ),
                    Text(
                      group?.name ?? 'Players & prep',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (group == null)
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: false,
                            label: Text('All players'),
                          ),
                          ButtonSegment(value: true, label: Text('Groups')),
                        ],
                        selected: {owner.showingGroups},
                        onSelectionChanged: (v) {
                          if (!mounted) return;
                          _search.clear();
                          owner.showGroups(v.single);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: Space.m),
                Wrap(
                  spacing: Space.s,
                  runSpacing: Space.s,
                  children: [
                    FilledButton.icon(
                      onPressed: owner.busy || owner.needsRetry
                          ? null
                          : groups
                          ? () => _group()
                          : group != null
                          ? () => _addMember(group)
                          : () => editPlayer(context, owner),
                      icon: const Icon(Icons.add),
                      label: Text(
                        groups
                            ? 'New group'
                            : group != null
                            ? 'Add players'
                            : 'Add player',
                      ),
                    ),
                    if (!groups)
                      OutlinedButton.icon(
                        onPressed: owner.busy || owner.needsRetry
                            ? null
                            : () => importPlayers(context, owner),
                        icon: const Icon(Icons.content_paste),
                        label: const Text('Paste players'),
                      ),
                    if (group != null) ...[
                      TextButton(
                        onPressed: owner.busy ? null : () => _group(old: group),
                        child: const Text('Edit group'),
                      ),
                      TextButton(
                        onPressed: () => widget.onGroupStudy(group),
                        child: const Text('Open group study'),
                      ),
                      TextButton(
                        onPressed: () => widget.onTrainGroup(group),
                        child: const Text('Train group study'),
                      ),
                      if (group.fields['study'] case final String study
                          when study.isNotEmpty)
                        TextButton(
                          onPressed: owner.busy
                              ? null
                              : () => owner.unlinkGroupStudy(group),
                          child: const Text('Unlink group study'),
                        ),
                      TextButton(
                        onPressed: () => widget.onCopy(group),
                        child: const Text('Copy prep sheet'),
                      ),
                      TextButton(
                        onPressed: () => widget.onExport(group),
                        child: const Text('Export prep sheet…'),
                      ),
                    ],
                    TextButton(
                      onPressed: owner.busy ? null : widget.onSaved,
                      child: const Text('Add saved players'),
                    ),
                    TextButton(
                      onPressed: owner.lookupRating == null
                          ? null
                          : owner.lookingUp
                          ? owner.stopLookup
                          : owner.updateRatings,
                      child: Text(
                        owner.lookingUp
                            ? 'Stop lookup'
                            : 'Update US Chess ratings',
                      ),
                    ),
                    IconButton(
                      onPressed: owner.busy ? null : owner.load,
                      tooltip: 'Reload players and groups',
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: Space.m),
                SearchField(
                  controller: _search,
                  hint: groups ? 'Search groups' : 'Search name, ID or account',
                  onChanged: owner.search,
                ),
                if (owner.busy) const LinearProgressIndicator(),
                if (owner.lookupStatus != null) Text(owner.lookupStatus!),
                for (final warning in owner.warnings) Text(warning),
                if (owner.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.s),
                    child: Wrap(
                      spacing: Space.s,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          owner.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        if (owner.needsRetry) ...[
                          TextButton(
                            onPressed: owner.busy ? null : owner.retry,
                            child: const Text('Retry save'),
                          ),
                          TextButton(
                            onPressed: owner.busy ? null : owner.discardFailed,
                            child: const Text('Discard failed edit and reload'),
                          ),
                        ] else
                          TextButton(
                            onPressed: owner.load,
                            child: const Text('Try again'),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: Space.s),
                Expanded(child: groups ? _groups() : _people()),
              ],
            ),
          ),
        ),
      );
    },
  );
  Widget _groups() {
    final groups = owner.groups
        .where((g) => g.name.toLowerCase().contains(owner.query.toLowerCase()))
        .toList();
    if (groups.isEmpty)
      return const Center(
        child: Text(
          'No groups to show. Create a group for an event or training session.',
        ),
      );
    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (context, i) {
        final g = groups[i];
        return Card(
          child: ListTile(
            title: Text(g.name),
            subtitle: Text(
              '${g.entries.length} players · ${g.entries.where((e) => e['prepared'] == true).length} prepared',
            ),
            onTap: () {
              _search.clear();
              owner.showGroup(g.id);
            },
            trailing: IconButton(
              tooltip: 'Remove group',
              icon: const Icon(Icons.delete_outline),
              onPressed: owner.busy
                  ? null
                  : () async {
                      if (await confirmAction(
                            context,
                            title: 'Remove ${g.name}?',
                            message:
                                'Players, saved games and studies stay in your library.',
                            confirm: 'Remove',
                          ) &&
                          mounted)
                        await owner.removeGroup(g);
                    },
            ),
          ),
        );
      },
    );
  }

  Widget _people() {
    final players = owner.visible;
    if (players.isEmpty)
      return Center(
        child: Text(
          owner.query.isNotEmpty
              ? 'No players match this search.'
              : owner.group == null
              ? 'Add a player with an online account or import a player list.'
              : 'Add players from your directory, or paste the event’s player list.',
        ),
      );
    return ListView.builder(
      itemCount: players.length,
      itemBuilder: (context, i) {
        final p = players[i];
        final group = owner.group;
        return _personCard(p, group);
      },
    );
  }

  Widget _personCard(Player p, PlayerGroup? group) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (group != null)
                  Checkbox(
                    value: group.prepared(p.id),
                    onChanged: owner.busy
                        ? null
                        : (value) => owner.saveGroup(
                            group.member(p.id, prepared: value),
                            expected: group,
                          ),
                  ),
                Expanded(
                  child: Text(
                    p.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (p.text('rating').isNotEmpty) Text(p.text('rating')),
                IconButton(
                  onPressed: owner.busy ? null : () => _remove(p),
                  tooltip: group == null
                      ? 'Remove player'
                      : 'Remove from group',
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            if (group != null)
              Text(
                group.prepared(p.id) ? 'Prepared' : 'Not prepared yet',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            Text(
              p.accounts.isEmpty
                  ? 'No online accounts linked'
                  : p.accounts
                        .map((a) => '${a.site.label}: ${a.username}')
                        .join(' · '),
            ),
            Text(_savedLine(widget.saved.of(p), p.files.length)),
            if (p.text('uscf_id').isNotEmpty)
              Text('US Chess ${p.text('uscf_id')}'),
            if (p.text('notes').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Space.s),
                child: Text(
                  p.text('notes'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            _personActions(p),
            PlayerLookup(player: p, owner: owner),
          ],
        ),
      ),
    );
  }

  Widget _personActions(Player p) => Wrap(
    spacing: Space.s,
    runSpacing: Space.xs,
    children: [
      TextButton.icon(
        onPressed: () => widget.onAnalyze(p),
        icon: const Icon(Icons.analytics_outlined),
        label: const Text('Analyze games'),
      ),
      TextButton(
        onPressed: owner.busy
            ? null
            : () => editPlayer(context, owner, player: p),
        child: const Text('Edit player'),
      ),
      TextButton(
        onPressed: () => widget.onLink(p),
        child: const Text('Link study…'),
      ),
      if (widget.saved.of(p) case final saved? when saved.deletable > 0)
        TextButton(
          onPressed: owner.busy || widget.saved.deleting.contains(p.id)
              ? null
              : () => _deleteGames(p),
          child: const Text('Delete saved games…'),
        ),
      ..._studyLinks(p),
      TextButton(
        onPressed: () => widget.onStudy(p),
        child: Text(
          p.text('prep_file').isEmpty ? 'New prep study' : 'Open prep study',
        ),
      ),
      if (p.text('prep_file').isNotEmpty)
        TextButton(
          onPressed: owner.busy ? null : () => owner.unlinkPrep(p),
          child: const Text('Unlink prep study'),
        ),
    ],
  );
  List<Widget> _studyLinks(Player player) => [
    for (final link in player.fields['studies'] as List? ?? const [])
      if (link is Map && link['path'] is String)
        InputChip(
          label: Text(
            link['chapter'] as String? ??
                p.basenameWithoutExtension(link['path'] as String),
          ),
          onPressed: () => widget.onLinkedStudy(
            link['path'] as String,
            link['chapter'] as String?,
          ),
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
/// so the card keeps its height when the count arrives.
String _savedLine(GamesSummary? saved, int files) {
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
