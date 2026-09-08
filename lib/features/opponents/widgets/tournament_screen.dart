import 'dart:async';

import 'package:flutter/material.dart';

import '../../../utils/app_messages.dart';
import '../models/person_record.dart';
import '../models/tournament.dart';
import '../services/opponent_store.dart';
import '../services/tournament_import.dart';
import 'opponent_actions.dart';
import 'player_cell.dart';
import 'player_import_panel.dart';
import 'player_table.dart';

class TournamentScreen extends StatefulWidget {
  const TournamentScreen({
    super.key,
    required this.tournamentId,
    this.store,
    this.actions,
  });
  final String tournamentId;
  final OpponentStore? store;
  final OpponentActions? actions;
  @override
  State<TournamentScreen> createState() => _TournamentScreenState();
}

class _TournamentScreenState extends State<TournamentScreen> {
  late final _store = widget.store ?? OpponentStore.instance;
  late final _actions = widget.actions ?? OpponentActions(store: _store);
  final _search = TextEditingController();
  bool _adding = false;
  bool _importing = false;
  String? _newPerson;
  String? _error;
  bool _busy = false;
  Tournament? get _group => _store.tournament(widget.tournamentId);

  @override
  void initState() {
    super.initState();
    unawaited(_run(_store.ensureLoaded));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!mounted || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _include(PersonRecord person) async {
    final group = _group!;
    await _store.saveTournament(
      group.withEntry(
        TournamentEntry(personId: person.id, rating: person.rating),
      ),
    );
  }

  Future<void> _new() async {
    final person = await _store.savePerson(
      PersonRecord.create(name: 'New player'),
    );
    await _include(person);
    if (mounted) {
      setState(() {
        _adding = false;
        _search.clear();
        _newPerson = person.id;
      });
    }
  }

  Future<void> _analyse(PersonRecord person) async {
    final info = await _actions.ensureGames(
      context,
      person,
      group: _group!.name,
    );
    if (info != null && mounted) Navigator.of(context).pop(info);
  }

  Future<void> _remove(PersonRecord person) async {
    final entry = _group!.entries[_group!.indexOf(person.id)];
    await _store.saveTournament(_group!.withoutPerson(person.id));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${person.name} removed from group'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => unawaited(
            _run(() async {
              if (_group != null) {
                await _store.saveTournament(_group!.withEntry(entry));
              }
            }),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (context, _) {
      final group = _group;
      if (!_store.isLoaded || group == null) {
        return Scaffold(
          appBar: AppBar(),
          body: Center(
            child: Text(
              _error ??
                  (_store.isLoaded
                      ? 'This group no longer exists.'
                      : 'Loading players…'),
            ),
          ),
        );
      }
      final people = [
        for (final e in group.entries) ?_store.person(e.personId),
      ];
      final matches = _store
          .searchPeople(_search.text)
          .map((p) => p.id)
          .toSet();
      return Scaffold(
        appBar: AppBar(
          title: SizedBox(
            width: 340,
            child: PlayerCell(
              key: ValueKey(group.id),
              value: group.name,
              label: 'Group name',
              validate: (name) => name.isEmpty
                  ? 'Enter a group name.'
                  : (_store.tournamentNamed(name) != null &&
                        _store.tournamentNamed(name)!.id != group.id)
                  ? 'That name is already used.'
                  : null,
              save: (name) async {
                await _store.saveTournament(_group!.copyWith(name: name));
              },
            ),
          ),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton(
                    key: const Key('tournament-add-opponent'),
                    onPressed: () {
                      if (mounted) setState(() => _adding = !_adding);
                    },
                    child: Text(_adding ? 'Close add players' : 'Add players'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      if (mounted) setState(() => _importing = !_importing);
                    },
                    child: Text(
                      _importing ? 'Close import' : 'Paste player list',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => _actions.openGroupStudy(context, group),
                          ),
                    child: const Text('Open group study'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => _actions.trainTournament(context, group),
                          ),
                    child: const Text('Train group study'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await _actions.fillFromUscf(context, group);
                          }),
                    child: const Text('Look up USCF ratings'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await _actions.saveAsText(context, group);
                          }),
                    child: const Text('Export notes'),
                  ),
                ],
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_adding)
              Container(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        FilledButton(
                          onPressed: _busy ? null : () => _run(_new),
                          child: const Text('New player row'),
                        ),
                        const SizedBox(width: 12),
                        const Text('Or add someone from your saved players:'),
                      ],
                    ),
                    SizedBox(
                      height: 110,
                      child: SingleChildScrollView(
                        child: Wrap(
                          spacing: 8,
                          children: [
                            for (final person in _store.people.where(
                              (p) => !group.contains(p.id),
                            ))
                              TextButton(
                                key: Key('add-opponent-${person.id}'),
                                onPressed: _busy
                                    ? null
                                    : () => _run(() => _include(person)),
                                child: Text('Add ${person.name}'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_importing)
              PlayerImportPanel(
                onImport: (list) async {
                  final result = await TournamentImport(
                    _store,
                  ).importList(list, tournament: _group);
                  if (mounted && context.mounted) {
                    setState(() => _importing = false);
                    showAppSnackBar(context, result.summary);
                  }
                },
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Wrap(
                spacing: 16,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 220,
                    child: TextField(
                      controller: _search,
                      decoration: const InputDecoration(
                        hintText: 'Search players',
                        isDense: true,
                      ),
                      onChanged: (_) {
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                  Text(
                    '${group.entries.length} players · ${group.preparedCount} prepared',
                  ),
                  const Text(
                    'Edit cells directly · Saved automatically · Separate accounts with commas',
                  ),
                ],
              ),
            ),
            Expanded(
              child: PlayerTable(
                store: _store,
                actions: _actions,
                group: group,
                people: people.where((p) => matches.contains(p.id)).toList(),
                newPersonId: _newPerson,
                onAnalyse: _analyse,
                onRemove: _remove,
              ),
            ),
          ],
        ),
      );
    },
  );
}
