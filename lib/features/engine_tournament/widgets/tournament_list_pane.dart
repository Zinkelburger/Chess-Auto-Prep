/// The history rail: every match ever run, newest first, with what happened
/// in it — so the record of your runs lives in the app rather than in a file
/// manager pointed at `Documents/engine_tournaments`.
///
/// A row answers the three questions you have before deciding to open one:
/// who played, how it ended, and when. Rows are grouped by day so the list
/// reads as a history rather than a pile, and a filter box appears once there
/// are enough of them to need one.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/time_format.dart';
import '../models/stored_tournament.dart';
import '../services/tournament_summary.dart';

/// Below this many runs a search box is clutter, not help.
const int _kFilterThreshold = 6;

class TournamentListPane extends StatefulWidget {
  const TournamentListPane({
    super.key,
    required this.tournaments,
    required this.selectedId,
    required this.runningId,
    required this.onSelect,
    required this.onNew,
    this.now,
  });

  final List<StoredTournament> tournaments;
  final String? selectedId;
  final String? runningId;
  final void Function(StoredTournament tournament) onSelect;
  final VoidCallback onNew;

  /// Fixed "today" for the day grouping. Only tests pass this.
  @visibleForTesting
  final DateTime? now;

  @override
  State<TournamentListPane> createState() => _TournamentListPaneState();
}

class _TournamentListPaneState extends State<TournamentListPane> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Name, engines and opening all match — the three things you remember a
  /// past run by.
  List<StoredTournament> get _visible {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.tournaments;
    return [
      for (final t in widget.tournaments)
        if ('${t.config.name} ${t.config.openingLabel} '
                '${t.config.engines.map((e) => e.name).join(' ')}'
            .toLowerCase()
            .contains(query))
          t,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final showFilter =
        widget.tournaments.length >= _kFilterThreshold || _query.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
          child: Row(
            children: [
              Text(
                'History',
                style: AppTextStyles.bodyStrong.copyWith(
                  color: AppColors.onSurfaceSoft,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${widget.tournaments.length}',
                style: AppTextStyles.caption,
              ),
              const Spacer(),
              IconButton(
                tooltip: 'New tournament',
                icon: const Icon(Icons.add, size: 20),
                onPressed: widget.onNew,
              ),
            ],
          ),
        ),
        if (showFilter)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              style: AppTextStyles.body,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Filter by name, engine or opening',
                hintStyle: AppTextStyles.hint,
                prefixIcon: const Icon(Icons.search, size: 18),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 34,
                  minHeight: 34,
                ),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear filter',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () => setState(() {
                          _search.clear();
                          _query = '';
                        }),
                      ),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        const Divider(height: 1, color: AppColors.divider),
        Expanded(child: _buildList(visible)),
      ],
    );
  }

  Widget _buildList(List<StoredTournament> visible) {
    if (widget.tournaments.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Nothing here yet. Start a match and it will be saved '
          'under Documents/engine_tournaments.',
          style: AppTextStyles.hint,
        ),
      );
    }
    if (visible.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'No tournament matches "${_query.trim()}".',
          style: AppTextStyles.hint,
        ),
      );
    }

    // Day headings are emitted inline rather than as a grouped list widget:
    // the list is already sorted newest-first, so a heading is simply the
    // first row of each run of same-day tournaments.
    final rows = <Widget>[];
    String? group;
    for (final tournament in visible) {
      final heading = tournamentDayGroup(tournament.createdAt, now: widget.now);
      if (heading != group) {
        group = heading;
        rows.add(_GroupHeading(label: heading));
      }
      rows.add(
        _TournamentTile(
          tournament: tournament,
          selected: tournament.id == widget.selectedId,
          running: tournament.id == widget.runningId,
          now: widget.now,
          onTap: () => widget.onSelect(tournament),
        ),
      );
    }
    return ListView(padding: const EdgeInsets.only(bottom: 8), children: rows);
  }
}

class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Text(
        label.toUpperCase(),
        style: AppTextStyles.caption.copyWith(
          color: AppColors.onSurfaceMuted,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _TournamentTile extends StatelessWidget {
  const _TournamentTile({
    required this.tournament,
    required this.selected,
    required this.running,
    required this.onTap,
    this.now,
  });

  final StoredTournament tournament;
  final bool selected;
  final bool running;
  final VoidCallback onTap;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final config = tournament.config;
    final outcome = tournamentOutcome(tournament);
    return Material(
      color: selected ? AppColors.surfaceContainer : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.hoverOverlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      config.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyStrong,
                    ),
                  ),
                  const SizedBox(width: 6),
                  TournamentStatusChip(
                    status: tournament.status,
                    running: running,
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                engineDisplayNames(config).join(' vs '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.caption,
              ),
              // The score is the point of the row: a run you can read the
              // result of is one you do not have to open.
              if (outcome != null) ...[
                const SizedBox(height: 3),
                Text(
                  outcome.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption.copyWith(
                    color: outcome.isDecided
                        ? AppColors.inkSoft
                        : AppColors.onSurfaceSoft,
                    fontWeight: outcome.isDecided
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
              ],
              const SizedBox(height: 3),
              Text(
                _footerLine(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.caption,
              ),
              if (running || tournament.status == TournamentStatus.running) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: tournament.progress,
                    minHeight: 3,
                    backgroundColor: AppColors.surfaceInset,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _footerLine() {
    final config = tournament.config;
    final parts = <String>[
      '${tournament.gamesPlayed}/${tournament.gamesTotal} games',
      config.timeControl.label,
      tournamentTimeLabel(tournament.createdAt, now: now),
    ];
    final finished = tournament.finishedAt;
    if (finished != null && !running) {
      parts.add(
        formatCompactDuration(finished.difference(tournament.createdAt)),
      );
    }
    return parts.join(' · ');
  }
}

class TournamentStatusChip extends StatelessWidget {
  const TournamentStatusChip({
    super.key,
    required this.status,
    this.running = false,
  });

  final TournamentStatus status;
  final bool running;

  @override
  Widget build(BuildContext context) {
    // The word carries the state; colour is reserved for the one state that
    // needs attention (failed).
    final effective = running ? TournamentStatus.running : status;
    final color = effective == TournamentStatus.failed
        ? AppColors.danger
        : AppColors.onSurfaceSoft;
    return Text(
      running ? 'Running' : status.label,
      style: AppTextStyles.caption.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
