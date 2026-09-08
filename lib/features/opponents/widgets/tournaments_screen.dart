import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/analysis_player_info.dart';
import '../../../widgets/common/confirm_dialog.dart';
import '../models/tournament.dart';
import '../services/opponent_store.dart';
import 'opponent_actions.dart';
import 'people_screen.dart';
import 'player_cell.dart';
import 'tournament_screen.dart';

class TournamentsScreen extends StatefulWidget {
  const TournamentsScreen({super.key, this.store, this.actions});
  final OpponentStore? store;
  final OpponentActions? actions;
  @override
  State<TournamentsScreen> createState() => _TournamentsScreenState();
}

class _TournamentsScreenState extends State<TournamentsScreen> {
  late final _store = widget.store ?? OpponentStore.instance;
  late final _actions = widget.actions ?? OpponentActions(store: _store);
  final _name = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _store.ensureLoaded();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _open(Tournament group) => _page(
    TournamentScreen(tournamentId: group.id, store: _store, actions: _actions),
  );
  Future<void> _page(Widget page) async {
    final picked = await Navigator.of(
      context,
    ).push<AnalysisPlayerInfo>(MaterialPageRoute(builder: (_) => page));
    if (picked != null && mounted) Navigator.of(context).pop(picked);
  }

  Future<void> _create() async {
    if (_busy) return;
    final name = _name.text.trim();
    if (name.isEmpty || _store.tournamentNamed(name) != null) {
      setState(
        () => _error = name.isEmpty
            ? 'Enter a group name.'
            : 'That group already exists.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final group = await _store.createTournament(name);
      _name.clear();
      if (mounted) await _open(group);
    } catch (e) {
      if (mounted) setState(() => _error = 'Not saved: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Tournament group) async {
    final ok = await confirmAction(
      context,
      title: 'Delete ${group.name}?',
      message: 'Players, saved games and studies stay in your library.',
      confirmLabel: 'Delete',
    );
    if (!ok) return;
    try {
      await _store.deleteTournament(group.id);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Groups'),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: OutlinedButton(
            key: const Key('tournaments-people'),
            onPressed: () =>
                _page(PeopleScreen(store: _store, actions: _actions)),
            child: const Text('All players'),
          ),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: _store,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 320,
                  child: TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'New group',
                      hintText: 'Boylston September',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _create(),
                  ),
                ),
                FilledButton(
                  key: const Key('tournaments-new'),
                  onPressed: !_store.isLoaded || _busy ? null : _create,
                  child: const Text('Create group'),
                ),
                const Text('A saved list of players to prepare against.'),
              ],
            ),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          Expanded(
            child: !_store.isLoaded
                ? const Center(child: CircularProgressIndicator())
                : _store.tournaments.isEmpty
                ? const Center(
                    child: Text(
                      'Create a group, or open All players to organize your saved accounts.',
                    ),
                  )
                : ListView(
                    children: [
                      for (final group in _store.tournaments)
                        Card(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: PlayerCell(
                                    key: ValueKey(group.id),
                                    value: group.name,
                                    label: 'Group name',
                                    validate: (name) => name.isEmpty
                                        ? 'Enter a name.'
                                        : _store.tournamentNamed(name) !=
                                                  null &&
                                              _store
                                                      .tournamentNamed(name)!
                                                      .id !=
                                                  group.id
                                        ? 'That name is already used.'
                                        : null,
                                    save: (name) async {
                                      await _store.saveTournament(
                                        _store
                                            .tournament(group.id)!
                                            .copyWith(name: name),
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Text(
                                  '${group.entries.length} players · ${group.preparedCount} prepared',
                                ),
                                const SizedBox(width: 16),
                                FilledButton(
                                  key: Key('tournament-${group.id}'),
                                  onPressed: () => _open(group),
                                  child: const Text('Open group'),
                                ),
                                IconButton(
                                  tooltip: 'Delete group',
                                  onPressed: () => _delete(group),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    ),
  );
}
