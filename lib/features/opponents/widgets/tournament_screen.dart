/// One tournament's field as a sheet: a row per opponent with the columns
/// of the spreadsheet this replaces (name · rating · USCF ID · Chess.com ·
/// Lichess · games on disk · notes), a "prepared" tick, and the actions that
/// used to mean switching apps: analyse their games, open or train their
/// prep file, look them up on US Chess, save the lot as text.
///
/// Tapping a row analyses the opponent: the screen pops with their game-set
/// (downloading it first if needed) and Player Analysis opens on it, with
/// this tournament as context so "next opponent" comes back here.
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
import '../models/person_record.dart';
import '../models/tournament.dart';
import 'opponent_actions.dart';
import '../services/opponent_store.dart';
import '../services/tournament_import.dart';
import 'add_opponent_dialog.dart';
import 'import_field_dialog.dart';
import 'person_edit_dialog.dart';
import 'tournament_details_dialog.dart';

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
  late final OpponentStore _store = widget.store ?? OpponentStore.instance;
  late final OpponentActions _actions =
      widget.actions ?? OpponentActions(store: _store);

  /// Saved game-sets by lower-case username; null until read.
  Map<String, AnalysisPlayerInfo>? _sets;

  Tournament? get _tournament => _store.tournament(widget.tournamentId);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    await _store.ensureLoaded();
    await _reloadSets();
  }

  Future<void> _reloadSets() async {
    final sets = await _actions.gameSetsByUsername();
    if (mounted) setState(() => _sets = sets);
  }

  // ── Field actions ──────────────────────────────────────────────

  Future<void> _addOpponent() async {
    final t = _tournament;
    if (t == null) return;
    final person = await showDialog<PersonRecord>(
      context: context,
      builder: (_) => AddOpponentDialog(
        store: _store,
        excludeIds: {for (final e in t.entries) e.personId},
      ),
    );
    if (person == null || !mounted) return;
    await _store.saveTournament(
      t.withEntry(TournamentEntry(personId: person.id, rating: person.rating)),
    );
  }

  Future<void> _importFile() async {
    final t = _tournament;
    if (t == null) return;
    final list = await showDialog<OpponentList>(
      context: context,
      builder: (_) => const ImportFieldDialog(),
    );
    if (list == null || !mounted) return;
    final result = await TournamentImport(
      _store,
    ).importList(list, tournament: t);
    if (mounted) showAppSnackBar(context, result.summary);
  }

  Future<void> _downloadMissing() async {
    final t = _tournament;
    if (t == null) return;
    await _actions.downloadField(context, t);
    await _reloadSets();
  }

  Future<void> _fillFromUscf() async {
    final t = _tournament;
    if (t == null) return;
    await _actions.fillFromUscf(context, t);
  }

  Future<void> _trainAll() async {
    final t = _tournament;
    if (t == null) return;
    await _actions.trainTournament(context, t);
  }

  Future<void> _saveAsText() async {
    final t = _tournament;
    if (t == null) return;
    await _actions.saveAsText(context, t);
  }

  Future<void> _editDetails() async {
    final t = _tournament;
    if (t == null) return;
    final details = await showDialog<TournamentDetails>(
      context: context,
      builder: (_) => TournamentDetailsDialog(
        initial: TournamentDetails(
          name: t.name,
          date: t.date,
          rounds: t.rounds,
        ),
        validateName: (n) {
          final clash = _store.tournamentNamed(n);
          return clash != null && clash.id != t.id
              ? 'There is already a tournament called that.'
              : null;
        },
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

  Future<void> _deleteTournament() async {
    final t = _tournament;
    if (t == null) return;
    final ok = await confirmAction(
      context,
      title: 'Delete ${t.name}?',
      message:
          'Removes the tournament and its field. The people stay in the '
          'directory and their prep files stay in Study.',
      confirmLabel: 'Delete',
    );
    if (!ok || !mounted) return;
    await _store.deleteTournament(t.id);
    if (mounted) Navigator.of(context).pop();
  }

  // ── Row actions ────────────────────────────────────────────────

  Future<void> _analyse(PersonRecord person) async {
    final t = _tournament;
    if (t == null) return;
    final info = await _actions.ensureGames(context, person, group: t.name);
    if (info == null || !mounted) return;
    Navigator.of(context).pop(info);
  }

  Future<void> _updateGames(PersonRecord person) async {
    final t = _tournament;
    if (t == null) return;
    await _actions.downloads.downloadOne(
      context,
      person.toPlayerInfo(
        group: t.name,
        monthsBack: OpponentActions.defaultMonthsBack,
      ),
    );
    await _reloadSets();
  }

  Future<void> _editPerson(PersonRecord person) async {
    final edited = await showDialog<PersonRecord>(
      context: context,
      builder: (_) => PersonEditDialog(person: person),
    );
    if (edited == null) return;
    await _store.savePerson(edited);
    // A changed handle means a different game-set name.
    await _reloadSets();
  }

  Future<void> _remove(PersonRecord person) async {
    final t = _tournament;
    if (t == null) return;
    final ok = await confirmAction(
      context,
      title: 'Remove ${person.name} from ${t.name}?',
      message: 'They stay in the directory, with their notes and prep file.',
      confirmLabel: 'Remove',
    );
    if (ok) await _store.saveTournament(t.withoutPerson(person.id));
  }

  Future<void> _setPrepared(TournamentEntry entry, bool value) async {
    final t = _tournament;
    if (t == null) return;
    await _store.saveTournament(t.withEntry(entry.copyWith(prepared: value)));
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final t = _tournament;
        if (!_store.isLoaded || t == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: _store.isLoaded
                  ? const Text('This tournament no longer exists.')
                  : const CircularProgressIndicator(),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t.name, overflow: TextOverflow.ellipsis),
                if (t.whenLine.isNotEmpty)
                  Text(t.whenLine, style: AppTextStyles.caption),
              ],
            ),
            actions: [
              FilledButton(
                key: const Key('tournament-add-opponent'),
                onPressed: _addOpponent,
                child: const Text('Add opponent'),
              ),
              const SizedBox(width: 4),
              AppOverflowMenu(
                entries: [
                  AppMenuEntry(
                    label: 'Import opponents from file…',
                    onRun: () => unawaited(_importFile()),
                  ),
                  AppMenuEntry(
                    label: 'Download missing games',
                    enabled: t.entries.isNotEmpty,
                    onRun: () => unawaited(_downloadMissing()),
                    hint:
                        'Fetches the last six months of games for everyone '
                        'with an online account and no games saved yet.',
                  ),
                  AppMenuEntry(
                    label: 'Fill ratings from US Chess',
                    enabled: t.entries.isNotEmpty,
                    onRun: () => unawaited(_fillFromUscf()),
                    hint:
                        'Looks up everyone with a US Chess ID and writes '
                        'their current regular rating into the directory.',
                  ),
                  AppMenuEntry(
                    label: 'Train all prep',
                    enabled: t.entries.isNotEmpty,
                    dividerAbove: true,
                    onRun: () => unawaited(_trainAll()),
                    hint:
                        'Every line in every prep file of this field, as '
                        'one training session.',
                  ),
                  AppMenuEntry(
                    label: 'Save as text…',
                    onRun: () => unawaited(_saveAsText()),
                    hint:
                        'The field as a table plus each opponent’s notes '
                        'and prep lines, in one readable file.',
                  ),
                  AppMenuEntry(
                    label: 'Details…',
                    dividerAbove: true,
                    onRun: () => unawaited(_editDetails()),
                  ),
                  AppMenuEntry(
                    label: 'Delete tournament',
                    onRun: () => unawaited(_deleteTournament()),
                  ),
                ],
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: t.entries.isEmpty ? _buildEmpty() : _buildSheet(t),
        );
      },
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Nobody in the field yet.',
            style: TextStyle(color: AppColors.onSurfaceMuted),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                onPressed: _addOpponent,
                child: const Text('Add opponent…'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: _importFile,
                child: const Text('Import from file…'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSheet(Tournament t) {
    final sets = _sets;
    // Odds only exist when the field came with a pairing simulation.
    final showOdds = t.entries.any((e) => e.pairingProb != null);
    return Column(
      children: [
        _HeaderRow(showOdds: showOdds),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: t.entries.length,
            itemBuilder: (_, i) {
              final entry = t.entries[i];
              final person = _store.person(entry.personId);
              if (person == null) return const SizedBox.shrink();
              return _OpponentRow(
                person: person,
                entry: entry,
                showOdds: showOdds,
                gameSet: sets == null
                    ? null
                    : _actions.gameSetFor(sets, person),
                setsKnown: sets != null,
                onAnalyse: () => _analyse(person),
                onPrepared: (v) => _setPrepared(entry, v),
                onOpenPrep: () => _actions.openPrepFile(context, person),
                onTrainPrep: () => _actions.trainPrepFile(context, person),
                onUpdateGames: () => _updateGames(person),
                onEdit: () => _editPerson(person),
                onRemove: () => _remove(person),
              );
            },
          ),
        ),
      ],
    );
  }
}

// Column widths, shared by the header and the rows so they line up.
const _wTick = 44.0;
const _wRating = 64.0;
const _wUscf = 96.0;
const _wGames = 72.0;
const _wOdds = 60.0;
const _wMenu = 44.0;
const _fName = 3;
const _fHandle = 2;
const _fNotes = 4;

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.showOdds});

  final bool showOdds;

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyles.caption.copyWith(fontWeight: FontWeight.w600);
    Widget cell(String text, {double? width, int? flex, TextAlign? align}) {
      final child = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(text, style: style, textAlign: align),
      );
      if (width != null) return SizedBox(width: width, child: child);
      return Expanded(flex: flex ?? 1, child: child);
    }

    return SizedBox(
      height: 36,
      child: Row(
        children: [
          cell('✓', width: _wTick, align: TextAlign.center),
          cell('Name', flex: _fName),
          cell('Rating', width: _wRating, align: TextAlign.right),
          cell('USCF ID', width: _wUscf),
          cell('Chess.com', flex: _fHandle),
          cell('Lichess', flex: _fHandle),
          cell('Games', width: _wGames, align: TextAlign.right),
          if (showOdds) cell('Odds', width: _wOdds, align: TextAlign.right),
          cell('Notes', flex: _fNotes),
          const SizedBox(width: _wMenu),
        ],
      ),
    );
  }
}

class _OpponentRow extends StatelessWidget {
  const _OpponentRow({
    required this.person,
    required this.entry,
    required this.showOdds,
    required this.gameSet,
    required this.setsKnown,
    required this.onAnalyse,
    required this.onPrepared,
    required this.onOpenPrep,
    required this.onTrainPrep,
    required this.onUpdateGames,
    required this.onEdit,
    required this.onRemove,
  });

  final PersonRecord person;
  final TournamentEntry entry;

  /// Whether the field carries pairing odds at all (the column is shared).
  final bool showOdds;
  final AnalysisPlayerInfo? gameSet;
  final bool setsKnown;
  final VoidCallback onAnalyse;
  final ValueChanged<bool> onPrepared;
  final VoidCallback onOpenPrep;
  final VoidCallback onTrainPrep;
  final VoidCallback onUpdateGames;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    const muted = AppTextStyles.muted;
    const mono = TextStyle(
      fontFamily: AppTextStyles.monoFamily,
      fontSize: 13,
      color: AppColors.ink,
      fontFeatures: AppTextStyles.tabularFigures,
    );
    Widget cell(Widget child, {double? width, int? flex}) {
      final padded = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: child,
      );
      if (width != null) return SizedBox(width: width, child: padded);
      return Expanded(flex: flex ?? 1, child: padded);
    }

    final rating = entry.rating ?? person.rating;
    final notes = person.notes.replaceAll(RegExp(r'\s+'), ' ').trim();
    final games = gameSet;

    return InkWell(
      key: Key('opponent-row-${person.id}'),
      onTap: onAnalyse,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            SizedBox(
              width: _wTick,
              child: Checkbox(
                key: Key('opponent-prepared-${person.id}'),
                value: entry.prepared,
                onChanged: (v) => onPrepared(v ?? false),
                visualDensity: VisualDensity.compact,
              ),
            ),
            cell(
              Text(
                person.title == null
                    ? person.name
                    : '${person.title} ${person.name}',
                overflow: TextOverflow.ellipsis,
              ),
              flex: _fName,
            ),
            cell(
              Text(
                rating == null ? '' : '$rating',
                textAlign: TextAlign.right,
                style: mono,
              ),
              width: _wRating,
            ),
            cell(Text(person.uscfId ?? '', style: mono), width: _wUscf),
            cell(
              Text(person.chesscom ?? '', overflow: TextOverflow.ellipsis),
              flex: _fHandle,
            ),
            cell(
              Text(person.lichess ?? '', overflow: TextOverflow.ellipsis),
              flex: _fHandle,
            ),
            cell(
              Text(
                !setsKnown
                    ? ''
                    : games == null
                    ? '—'
                    : '${games.gameCount}',
                textAlign: TextAlign.right,
                style: games == null
                    ? mono.copyWith(color: AppColors.onSurfaceMuted)
                    : mono,
              ),
              width: _wGames,
            ),
            if (showOdds)
              cell(
                Tooltip(
                  message: entry.likelyRound == null
                      ? 'Chance of being paired'
                      : 'Chance of being paired · likely round ${entry.likelyRound}',
                  waitDuration: const Duration(milliseconds: 600),
                  child: Text(
                    entry.pairingProb == null
                        ? ''
                        : '${(entry.pairingProb! * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: mono,
                  ),
                ),
                width: _wOdds,
              ),
            cell(
              Tooltip(
                message: notes,
                waitDuration: const Duration(milliseconds: 600),
                child: Text(
                  notes,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              ),
              flex: _fNotes,
            ),
            SizedBox(
              width: _wMenu,
              child: AppOverflowMenu(
                entries: [
                  AppMenuEntry(
                    label: games == null
                        ? 'Download games and analyse'
                        : 'Analyse games',
                    enabled: person.hasAccount,
                    onRun: onAnalyse,
                  ),
                  AppMenuEntry(label: 'Open prep file', onRun: onOpenPrep),
                  AppMenuEntry(label: 'Train prep file', onRun: onTrainPrep),
                  if (games != null)
                    AppMenuEntry(
                      label: 'Download the latest games',
                      onRun: onUpdateGames,
                    ),
                  AppMenuEntry(
                    label: 'Edit…',
                    dividerAbove: true,
                    onRun: onEdit,
                  ),
                  AppMenuEntry(
                    label: 'Remove from tournament',
                    onRun: onRemove,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
