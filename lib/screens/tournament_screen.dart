/// Tournament mode: import a field, see who you are likely to play, and
/// prepare the lines that actually matter.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/tournament/models/roster_entry.dart';
import '../features/tournament/services/event_simulator.dart';
import '../features/tournament/services/player_directory.dart';
import '../features/tournament/services/tournament_session.dart';
import '../features/tournament/widgets/prep_report_panel.dart';
import '../features/tournament/widgets/roster_table.dart';
import '../features/tournament/widgets/tournament_controls.dart';
import '../theme/app_colors.dart';

class TournamentScreen extends StatefulWidget {
  const TournamentScreen({super.key});

  @override
  State<TournamentScreen> createState() => _TournamentScreenState();
}

class _TournamentScreenState extends State<TournamentScreen> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    // The directory is a bundled asset; loading it early keeps the first
    // "Resolve accounts" press from stalling.
    PlayerDirectory.ensureLoaded();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final session = context.read<TournamentSession>();
      session.load();
      // The standalone MCP server edits the same file from another process.
      session.startWatching();
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TournamentSession>();

    return Row(
      children: [
        SizedBox(
          width: 380,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _RosterHeader(session: session),
              const Divider(height: 1),
              Expanded(
                child: RosterTable(
                  roster: session.roster,
                  simulation: session.simulation,
                  selectedId: _selectedId,
                  onSelect: (entry) => setState(() => _selectedId = entry.id),
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _RightPane(session: session, selectedId: _selectedId),
        ),
      ],
    );
  }
}

class _RosterHeader extends StatelessWidget {
  final TournamentSession session;

  const _RosterHeader({required this.session});

  @override
  Widget build(BuildContext context) {
    final roster = session.roster;
    final total = roster.entries.length;
    final resolved = roster.resolvedCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            roster.eventName.isEmpty ? 'Entry list' : roster.eventName,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            total == 0
                ? 'No entrants'
                : '$total entrants · $resolved with an account · '
                      '${roster.rounds} rounds'
                      '${roster.accelerated ? ' · accelerated' : ''}',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
          ),
          if (roster.me == null && total > 0) ...[
            const SizedBox(height: 6),
            Text(
              'Nobody is marked as you — select an entrant and press '
              '"This is me" to get pairing probabilities.',
              style: TextStyle(fontSize: 11, color: AppColors.warning),
            ),
          ],
        ],
      ),
    );
  }
}

class _RightPane extends StatelessWidget {
  final TournamentSession session;
  final String? selectedId;

  const _RightPane({required this.session, required this.selectedId});

  @override
  Widget build(BuildContext context) {
    final selected = selectedId == null
        ? null
        : session.roster.entries.where((e) => e.id == selectedId).firstOrNull;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The selected entrant leads: clicking a name in the table should
          // surface that player, not bury their card under four control cards
          // the user has already scrolled past.
          if (selected != null) ...[
            _SelectedEntrantCard(session: session, entry: selected),
            const SizedBox(height: 16),
          ],
          TournamentControls(session: session, selected: selected),
          const SizedBox(height: 16),
          PrepReportPanel(session: session),
        ],
      ),
    );
  }
}

class _SelectedEntrantCard extends StatelessWidget {
  final TournamentSession session;
  final RosterEntry entry;

  const _SelectedEntrantCard({required this.session, required this.entry});

  @override
  Widget build(BuildContext context) {
    final identity = entry.identity;
    final probability = session.simulation.opponents
        .where((o) => o.playerId == entry.id)
        .firstOrNull;

    return Card(
      color: AppColors.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.name,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              [
                if (entry.uscfId != null) 'USCF ${entry.uscfId}',
                if (entry.rating != null) 'rated ${entry.rating}',
                if (entry.section != null) entry.section!,
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
            ),
            if (probability != null) ...[
              const SizedBox(height: 10),
              Text(
                '${(probability.probAny * 100).toStringAsFixed(0)}% to face — '
                '${(probability.probAsWhite * 100).toStringAsFixed(0)}% with '
                'White, ${(probability.probAsBlack * 100).toStringAsFixed(0)}% '
                'with Black'
                '${probability.mostLikelyRound != null ? ' · most likely round ${probability.mostLikelyRound}' : ''}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
            if (identity != null) ...[
              const SizedBox(height: 10),
              Text(
                'Account: ${identity.chesscomUsername ?? identity.lichessUsername ?? '—'}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 4),
              // The evidence is shown verbatim so a weak match reads as weak.
              Text(
                identity.evidence ?? 'No evidence recorded.',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.onSurfaceMuted,
                  fontStyle: FontStyle.italic,
                ),
              ),
              if (identity.alternates.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Other candidates: ${identity.alternates.join(', ')}',
                  style: TextStyle(fontSize: 11, color: AppColors.warning),
                ),
              ],
              if (!identity.isActionable && identity.hasAccount) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    onPressed: () {
                      session.confirmIdentity(playerId: entry.id);
                      session.save();
                    },
                    child: const Text('Confirm this account'),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: entry.isMe
                      ? null
                      : () {
                          session.updateEntry(entry.id, isMe: true);
                          session.save();
                        },
                  child: const Text('This is me'),
                ),
                OutlinedButton(
                  onPressed: () {
                    session.updateEntry(entry.id, withdrawn: !entry.withdrawn);
                    session.save();
                  },
                  child: Text(entry.withdrawn ? 'Reinstate' : 'Mark withdrawn'),
                ),
                OutlinedButton(
                  onPressed: () {
                    session.updateEntry(
                      entry.id,
                      attendanceProb: entry.attendanceProb >= 1.0 ? 0.5 : 1.0,
                    );
                    session.save();
                  },
                  child: Text(
                    entry.attendanceProb >= 1.0
                        ? 'Mark as a maybe'
                        : 'Mark as confirmed',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Default simulation settings used by the screen's Simulate button.
const kScreenSimConfig = SimulationConfig(trials: 2000);
