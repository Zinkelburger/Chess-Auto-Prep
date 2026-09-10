import 'dart:async';

import 'package:flutter/material.dart';

import '../../../utils/app_messages.dart';
import '../../../screens/analysis_screen.dart';
import '../../../models/analysis_player_info.dart';
import '../../../services/opponent_list.dart';
import '../../../theme/app_text_styles.dart';
import '../services/tournament_import.dart';
import 'player_import_panel.dart';
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
  bool _importing = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _store.ensureLoaded();
      if (!_store.savedAccountsImported) {
        await _actions.addSavedPlayers();
        await _store.markSavedAccountsImported();
      }
      if (mounted) setState(() => _reload++);
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
    if (info == null || !mounted) return;
    await _openGames(info);
  }

  Future<void> _openGames(AnalysisPlayerInfo info) async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => AnalysisScreen(initialPlayer: info)),
    );
  }

  Future<void> _import(OpponentList list) async {
    final importer = TournamentImport(_store);
    for (final row in list.opponents) {
      await importer.importPerson(row);
    }
    if (!mounted) return;
    setState(() {
      _importing = false;
      _search.clear();
    });
    showAppSnackBar(
      context,
      '${list.opponents.length} players added or updated.',
    );
  }

  Future<void> _remove(PersonRecord person) async {
    final ok = await confirmAction(
      context,
      title: 'Delete ${person.name}?',
      message:
          'Deletes this player record. Saved games and linked studies stay on disk.',
      confirmLabel: 'Delete',
    );
    if (ok) await _store.deletePerson(person.id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Player database')),
    body: ListenableBuilder(
      listenable: _store,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 280,
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      hintText: 'Search name, ID or account',
                      filled: true,
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: (_) {
                      if (mounted) setState(() {});
                    },
                  ),
                ),
                FilledButton.icon(
                  key: const Key('people-add'),
                  onPressed: _store.isLoaded ? _add : null,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add player'),
                ),
                OutlinedButton(
                  onPressed: _busy || !_store.isLoaded ? null : _savedAccounts,
                  child: Text(_busy ? 'Linking…' : 'Add saved accounts'),
                ),
                OutlinedButton.icon(
                  key: const Key('people-paste'),
                  onPressed: !_store.isLoaded
                      ? null
                      : () {
                          if (mounted) setState(() => _importing = !_importing);
                        },
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: Text(_importing ? 'Close import' : 'Paste players'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Text(
                  'All players · ${_store.people.length}',
                  style: AppTextStyles.bodyStrong,
                ),
                const SizedBox(width: 24),
                const Expanded(
                  child: Text(
                    'Edit cells to save automatically. Use commas for multiple accounts.',
                    style: AppTextStyles.muted,
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_importing)
            PlayerImportPanel(
              importLabel: 'Add to database',
              onImport: _import,
            ),
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
                    onOpenGames: _openGames,
                    onRemove: _remove,
                  ),
          ),
        ],
      ),
    ),
  );
}
