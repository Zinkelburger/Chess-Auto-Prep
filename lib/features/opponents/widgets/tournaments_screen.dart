/// The tournaments you are preparing for, and the ones you have prepared
/// for: one row each, newest first. Pushed from the player picker's third
/// source; pops with an [AnalysisPlayerInfo] when the user asks to analyse
/// someone from a sheet, so the picker can hand them to Player Analysis.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/analysis_player_info.dart';
import '../../../services/opponent_list.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/app_messages.dart';
import '../../../widgets/app_overflow_menu.dart';
import '../../../widgets/common/confirm_dialog.dart';
import '../models/tournament.dart';
import 'opponent_actions.dart';
import '../services/opponent_store.dart';
import '../services/tournament_import.dart';
import 'import_field_dialog.dart';
import 'people_screen.dart';
import 'tournament_details_dialog.dart';
import 'tournament_screen.dart';

class TournamentsScreen extends StatefulWidget {
  const TournamentsScreen({super.key, this.store, this.actions});

  /// Injectable for tests; the app-wide store otherwise.
  final OpponentStore? store;
  final OpponentActions? actions;

  @override
  State<TournamentsScreen> createState() => _TournamentsScreenState();
}

class _TournamentsScreenState extends State<TournamentsScreen> {
  late final OpponentStore _store = widget.store ?? OpponentStore.instance;
  late final OpponentActions _actions =
      widget.actions ?? OpponentActions(store: _store);

  @override
  void initState() {
    super.initState();
    unawaited(_store.ensureLoaded());
  }

  Future<void> _open(Tournament t) async {
    final picked = await Navigator.of(context).push<AnalysisPlayerInfo>(
      MaterialPageRoute(
        builder: (_) => TournamentScreen(
          tournamentId: t.id,
          store: _store,
          actions: _actions,
        ),
      ),
    );
    if (picked != null && mounted) Navigator.of(context).pop(picked);
  }

  Future<void> _openPeople() async {
    final picked = await Navigator.of(context).push<AnalysisPlayerInfo>(
      MaterialPageRoute(
        builder: (_) => PeopleScreen(store: _store, actions: _actions),
      ),
    );
    if (picked != null && mounted) Navigator.of(context).pop(picked);
  }

  String? _validateName(String name, {String? exceptId}) {
    final clash = _store.tournamentNamed(name);
    if (clash != null && clash.id != exceptId) {
      return 'There is already a tournament called that.';
    }
    return null;
  }

  Future<void> _newTournament() async {
    final details = await showDialog<TournamentDetails>(
      context: context,
      builder: (_) => TournamentDetailsDialog(validateName: _validateName),
    );
    if (details == null || !mounted) return;
    final t = await _store.createTournament(
      details.name,
      date: details.date,
      rounds: details.rounds,
    );
    if (mounted) await _open(t);
  }

  Future<void> _importFile() async {
    final list = await showDialog<OpponentList>(
      context: context,
      builder: (_) => const ImportFieldDialog(),
    );
    if (list == null || !mounted) return;
    final result = await TournamentImport(_store).importList(list);
    if (!mounted) return;
    showAppSnackBar(context, result.summary);
    await _open(result.tournament);
  }

  Future<void> _editDetails(Tournament t) async {
    final details = await showDialog<TournamentDetails>(
      context: context,
      builder: (_) => TournamentDetailsDialog(
        initial: TournamentDetails(
          name: t.name,
          date: t.date,
          rounds: t.rounds,
        ),
        validateName: (n) => _validateName(n, exceptId: t.id),
      ),
    );
    if (details == null) return;
    await _store.saveTournament(
      t.copyWith(
        name: details.name,
        date: details.date,
        clearDate: details.date == null,
        rounds: details.rounds,
        clearRounds: details.rounds == null,
      ),
    );
  }

  Future<void> _delete(Tournament t) async {
    final ok = await confirmAction(
      context,
      title: 'Delete ${t.name}?',
      message:
          'Removes the tournament and its field. The people stay in the '
          'directory and their prep files stay in Study.',
      confirmLabel: 'Delete',
    );
    if (ok) await _store.deleteTournament(t.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tournaments'),
        actions: [
          TextButton(
            key: const Key('tournaments-people'),
            onPressed: _openPeople,
            child: const Text('People'),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              key: const Key('tournaments-new'),
              onPressed: _newTournament,
              child: const Text('New tournament'),
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
          final tournaments = _store.tournaments;
          if (tournaments.isEmpty) return _buildEmpty();
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: tournaments.length,
            itemBuilder: (_, i) => _TournamentTile(
              tournament: tournaments[i],
              onOpen: () => _open(tournaments[i]),
              onDetails: () => _editDetails(tournaments[i]),
              onDelete: () => _delete(tournaments[i]),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'No tournaments yet.',
            style: TextStyle(color: AppColors.onSurfaceMuted),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                onPressed: _newTournament,
                child: const Text('New tournament…'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                key: const Key('tournaments-import'),
                onPressed: _importFile,
                child: const Text('Import a field file…'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TournamentTile extends StatelessWidget {
  const _TournamentTile({
    required this.tournament,
    required this.onOpen,
    required this.onDetails,
    required this.onDelete,
  });

  final Tournament tournament;
  final VoidCallback onOpen;
  final VoidCallback onDetails;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final n = tournament.entries.length;
    final facts = [
      if (tournament.whenLine.isNotEmpty) tournament.whenLine,
      '$n opponent${n == 1 ? '' : 's'}',
      if (n > 0) '${tournament.preparedCount} prepared',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: Key('tournament-${tournament.id}'),
        onTap: onOpen,
        title: Text(tournament.name),
        subtitle: Text(facts, style: AppTextStyles.muted),
        trailing: AppOverflowMenu(
          entries: [
            AppMenuEntry(label: 'Details…', onRun: onDetails),
            AppMenuEntry(label: 'Delete tournament', onRun: onDelete),
          ],
        ),
      ),
    );
  }
}
