/// The directory: everyone you have ever entered, searchable, so a regular
/// is one tap in the next tournament instead of a re-typed row.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/app_overflow_menu.dart';
import '../../../widgets/common/confirm_dialog.dart';
import '../../../widgets/common/list_search_field.dart';
import '../models/person_record.dart';
import 'opponent_actions.dart';
import '../services/opponent_store.dart';
import 'person_edit_dialog.dart';

class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key, this.store, this.actions});

  final OpponentStore? store;
  final OpponentActions? actions;

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  late final OpponentStore _store = widget.store ?? OpponentStore.instance;
  late final OpponentActions _actions =
      widget.actions ?? OpponentActions(store: _store);
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_store.ensureLoaded());
  }

  Future<void> _add() async {
    final created = await showDialog<PersonRecord>(
      context: context,
      builder: (_) => const PersonEditDialog(),
    );
    if (created != null) await _store.savePerson(created);
  }

  Future<void> _edit(PersonRecord person) async {
    final edited = await showDialog<PersonRecord>(
      context: context,
      builder: (_) => PersonEditDialog(person: person),
    );
    if (edited != null) await _store.savePerson(edited);
  }

  Future<void> _analyse(PersonRecord person) async {
    final info = await _actions.ensureGames(context, person);
    if (info != null && mounted) Navigator.of(context).pop(info);
  }

  Future<void> _delete(PersonRecord person) async {
    final n = _store.tournamentCountFor(person.id);
    final ok = await confirmAction(
      context,
      title: 'Delete ${person.name}?',
      message: [
        if (n > 0) 'Also removes them from $n tournament${n == 1 ? '' : 's'}.',
        'Their prep file stays in Study; their downloaded games stay in '
            'Player Analysis.',
      ].join(' '),
      confirmLabel: 'Delete',
    );
    if (ok) await _store.deletePerson(person.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              key: const Key('people-add'),
              onPressed: _add,
              child: const Text('Add person'),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          if (!_store.isLoaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_store.people.isEmpty) {
            return const Center(
              child: Text(
                'Nobody yet.',
                style: TextStyle(color: AppColors.onSurfaceMuted),
              ),
            );
          }
          final people = _store.searchPeople(_query);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: ListSearchField(
                  hintText: 'Search people',
                  autofocus: true,
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Expanded(
                child: people.isEmpty
                    ? Center(
                        child: Text(
                          'Nobody matches "$_query"',
                          style: const TextStyle(
                            color: AppColors.onSurfaceMuted,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: people.length,
                        itemBuilder: (_, i) => _PersonTile(
                          person: people[i],
                          tournaments: _store.tournamentCountFor(people[i].id),
                          onEdit: () => _edit(people[i]),
                          onAnalyse: () => _analyse(people[i]),
                          onOpenPrep: () =>
                              _actions.openPrepFile(context, people[i]),
                          onDelete: () => _delete(people[i]),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({
    required this.person,
    required this.tournaments,
    required this.onEdit,
    required this.onAnalyse,
    required this.onOpenPrep,
    required this.onDelete,
  });

  final PersonRecord person;
  final int tournaments;
  final VoidCallback onEdit;
  final VoidCallback onAnalyse;
  final VoidCallback onOpenPrep;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final facts = [
      if (person.rating != null) '${person.rating}',
      if (person.uscfId != null) 'USCF ${person.uscfId}',
      if (person.handlesLine.isNotEmpty) person.handlesLine,
      if (tournaments > 0)
        'in $tournaments tournament${tournaments == 1 ? '' : 's'}',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: Key('person-${person.id}'),
        onTap: onEdit,
        title: Text(person.name),
        subtitle: Text(
          facts.isEmpty ? 'No details yet' : facts,
          style: AppTextStyles.muted,
        ),
        trailing: AppOverflowMenu(
          entries: [
            AppMenuEntry(
              label: 'Analyse games',
              enabled: person.hasAccount,
              onRun: onAnalyse,
            ),
            AppMenuEntry(label: 'Open prep file', onRun: onOpenPrep),
            AppMenuEntry(label: 'Edit…', dividerAbove: true, onRun: onEdit),
            AppMenuEntry(label: 'Delete', onRun: onDelete),
          ],
        ),
      ),
    );
  }
}
