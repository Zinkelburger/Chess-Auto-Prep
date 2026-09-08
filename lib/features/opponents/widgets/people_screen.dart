import 'dart:async';

import 'package:flutter/material.dart';

import '../../../utils/app_messages.dart';
import '../../../widgets/common/confirm_dialog.dart';
import '../models/person_record.dart';
import '../services/opponent_store.dart';
import 'opponent_actions.dart';
import 'player_table.dart';

class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key, this.store, this.actions});
  final OpponentStore? store;
  final OpponentActions? actions;
  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  late final _store = widget.store ?? OpponentStore.instance;
  late final _actions = widget.actions ?? OpponentActions(store: _store);
  final _search = TextEditingController();
  String? _newPerson;
  String? _error;
  int _reload = 0;
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
    _search.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    try {
      final person = await _store.savePerson(
        PersonRecord.create(name: 'New player'),
      );
      if (mounted) {
        setState(() {
          _search.clear();
          _newPerson = person.id;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Not saved: $e');
    }
  }

  Future<void> _savedAccounts() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final count = await _actions.addSavedPlayers();
      if (mounted) {
        setState(() {
          _reload++;
          _search.clear();
        });
        showAppSnackBar(
          context,
          'Added $count players. Existing accounts are linked.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _analyse(PersonRecord person) async {
    final info = await _actions.ensureGames(context, person);
    if (info != null && mounted) Navigator.of(context).pop(info);
  }

  Future<void> _remove(PersonRecord person) async {
    final ok = await confirmAction(
      context,
      title: 'Delete ${person.name}?',
      message:
          'Removes this player from all groups. Their saved games and studies stay on disk.',
      confirmLabel: 'Delete',
    );
    if (ok) await _store.deletePerson(person.id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Players')),
    body: ListenableBuilder(
      listenable: _store,
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 240,
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
                FilledButton(
                  key: const Key('people-add'),
                  onPressed: _store.isLoaded ? _add : null,
                  child: const Text('Add player'),
                ),
                OutlinedButton(
                  onPressed: _busy || !_store.isLoaded ? null : _savedAccounts,
                  child: Text(_busy ? 'Linking…' : 'Add saved accounts'),
                ),
                const Text(
                  'Edit cells directly · Saved automatically · Separate accounts with commas',
                ),
              ],
            ),
          ),
          if (_error != null) Text(_error!),
          Expanded(
            child: !_store.isLoaded
                ? const Center(child: CircularProgressIndicator())
                : PlayerTable(
                    key: ValueKey(_reload),
                    store: _store,
                    actions: _actions,
                    people: _store.searchPeople(_search.text),
                    newPersonId: _newPerson,
                    onAnalyse: _analyse,
                    onRemove: _remove,
                  ),
          ),
        ],
      ),
    ),
  );
}
