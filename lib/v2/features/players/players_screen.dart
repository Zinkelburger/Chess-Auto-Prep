import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/choice_dialog.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/name_dialog.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import '../../chess/players/player.dart';
import 'player_dialogs.dart';
import 'players.dart';

class PlayersScreen extends StatefulWidget {
  const PlayersScreen({
    super.key,
    required this.players,
    required this.onAnalyze,
    required this.onStudy,
    required this.onSaved,
  });
  final Players players;
  final ValueChanged<Player> onAnalyze;
  final ValueChanged<Player> onStudy;
  final VoidCallback onSaved;
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
    final name = await showNameDialog(
      context,
      title: old == null ? 'New group' : 'Rename group',
      label: 'Group name',
      confirm: 'Save',
    );
    if (!mounted || name == null) return;
    final group = old?.edited({'name': name}) ?? PlayerGroup.create(name);
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
    final yes = await confirmAction(
      context,
      title: group == null
          ? 'Remove ${player.name}?'
          : 'Remove from ${group.name}?',
      message: 'Saved games and studies stay on disk.',
      confirm: 'Remove',
    );
    if (!yes || !mounted) return;
    if (group == null) {
      await owner.remove(player);
    } else {
      await owner.saveGroup(
        group.member(player.id, remove: true),
        expected: group,
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: owner,
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
                        child: const Text('Rename'),
                      ),
                      TextButton(
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(
                              text: groupNotes(group, owner.players),
                            ),
                          );
                          if (context.mounted)
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Prep notes copied as Markdown.'),
                              ),
                            );
                        },
                        child: const Text('Copy prep sheet'),
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
        onPressed: () => widget.onStudy(p),
        child: Text(
          p.text('prep_file').isEmpty ? 'New prep study' : 'Open prep study',
        ),
      ),
    ],
  );
}

String groupNotes(PlayerGroup group, List<Player> players) {
  String safe(String value) =>
      value.replaceAll('|', r'\|').replaceAll('\n', '<br>');
  return '# ${group.name}\n\n| Player | Rating | Accounts | Prepared |\n| --- | --- | --- | --- |\n${[for (final player in players.where((p) => group.contains(p.id))) '| ${safe(player.name)} | ${player.text('rating')} | ${safe(player.accounts.map((a) => '${a.site.label}: ${a.username}').join(', '))} | ${group.prepared(player.id) ? 'Yes' : 'No'} |'].join('\n')}\n\n${[for (final player in players.where((p) => group.contains(p.id))) '## ${player.name}\n\n${player.text('notes')}\n${player.text('prep_file')}'].join('\n\n')}\n';
}
