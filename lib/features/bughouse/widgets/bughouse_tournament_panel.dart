/// The engine tournament panel: play a position out N times, read the score,
/// and find the earlier runs.
///
/// The engine tournament screen's shape, cut down to what fits beside two
/// boards: a run button, the history of runs, and the selected run's score
/// and games. It lives in the lab rather than on that screen because a
/// bughouse game is two boards, and the lab already has the viewer for one —
/// clicking a game in the table puts it on the boards to the left.
///
/// The number that leads is **the score of the opening** — how the pair
/// holding White on board 1 did across every game, which is the question a
/// tournament from a set position is asked. The crosstable, which measures
/// the engines against each other, is at the bottom and shut.
library;

import 'package:flutter/material.dart';

import '../../../models/crosstable.dart';
import '../../../models/game_outcome.dart';
import '../../../services/crosstable_builder.dart';
import '../../../widgets/common/choice_field.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/time_format.dart';
import '../../../widgets/crosstable_view.dart';
import '../../../widgets/match_games_table.dart';
import '../controllers/bughouse_controller.dart';
import '../controllers/bughouse_tournament_controller.dart';
import '../models/bughouse_state.dart';
import '../models/bughouse_tournament.dart';
import 'bughouse_panel_section.dart';
import 'new_bughouse_match_dialog.dart';

class BughouseTournamentPanel extends StatelessWidget {
  const BughouseTournamentPanel({super.key, required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final matches = controller.tournaments;
    return AnimatedBuilder(
      animation: matches,
      builder: (context, _) {
        if (matches.isLoading) {
          return const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final selected = matches.selected;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _RunBar(controller: controller, matches: matches),
            if (matches.error != null) ...[
              const SizedBox(height: 8),
              _ErrorBanner(message: matches.error!),
            ],
            if (matches.matches.isNotEmpty) ...[
              const SizedBox(height: 10),
              _History(matches: matches),
              const SizedBox(height: 10),
              const Divider(height: 1, color: AppColors.divider),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: selected == null
                  ? const _EmptyState()
                  : _MatchView(
                      controller: controller,
                      matches: matches,
                      match: selected,
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// Start one, or stop the one running.
class _RunBar extends StatelessWidget {
  const _RunBar({required this.controller, required this.matches});

  final BughouseController controller;
  final BughouseTournamentController matches;

  @override
  Widget build(BuildContext context) {
    final running = matches.isRunning;
    return Row(
      children: [
        if (running) ...[
          Expanded(
            child: Text(
              'Playing game ${matches.liveGameNumber}'
              ' of ${matches.selected?.config.games ?? 0}',
              style: AppTextStyles.bodyStrong,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: AppTextStyles.caption,
            ),
            icon: const Icon(Icons.stop, size: 15),
            label: const Text('Stop'),
            onPressed: matches.stop,
          ),
        ] else
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: AppTextStyles.caption,
            ),
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text('New tournament'),
            onPressed: () => showNewBughouseMatchDialog(context, controller),
          ),
      ],
    );
  }
}

/// Every run, newest first — the engine tournament's history rail, laid
/// flat. A row carries the score so a run you can read the result of is one
/// you do not have to open.
class _History extends StatelessWidget {
  const _History({required this.matches});

  final BughouseTournamentController matches;

  /// Four rows before the list scrolls: the history is a way in, not the
  /// thing you look at.
  static const double _rowHeight = 44;
  static const int _visibleRows = 4;

  @override
  Widget build(BuildContext context) {
    final selected = matches.selected;
    final rows = matches.matches;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('HISTORY', style: AppTextStyles.eyebrow),
            const SizedBox(width: 8),
            Text('${rows.length}', style: AppTextStyles.caption),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: _rowHeight * rows.length.clamp(1, _visibleRows),
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemExtent: _rowHeight,
            itemCount: rows.length,
            itemBuilder: (context, i) => _HistoryRow(
              key: ValueKey('bughouse-history-${rows[i].id}'),
              match: rows[i],
              selected: rows[i].id == selected?.id,
              running: matches.isRunning && rows[i].id == selected?.id,
              onTap: () => matches.select(rows[i].id),
            ),
          ),
        ),
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    super.key,
    required this.match,
    required this.selected,
    required this.running,
    required this.onTap,
  });

  final StoredBughouseTournament match;
  final bool selected;
  final bool running;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final config = match.config;
    final status = running
        ? 'Running'
        : match.status == BughouseTournamentStatus.completed
        ? ''
        : match.status.label;
    return Material(
      color: selected ? AppColors.surfaceContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        hoverColor: AppColors.hoverOverlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
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
                  const SizedBox(width: 8),
                  Text(
                    match.openingScore.played == 0
                        ? '—'
                        : match.openingScoreLabel,
                    style: AppTextStyles.mono.copyWith(
                      color: match.status == BughouseTournamentStatus.failed
                          ? AppColors.danger
                          : AppColors.ink,
                    ),
                  ),
                ],
              ),
              Text(
                [
                  '${match.gamesPlayed}/${config.games} games',
                  config.participants.first.budget.label,
                  formatTimeAgo(match.createdAt),
                  if (status.isNotEmpty) status,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.caption,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('No tournaments yet', style: AppTextStyles.emptyStateTitle),
        SizedBox(height: 8),
        Text(
          'Set a position up on the boards, then play it out. Every game '
          'lands here to click through.',
          style: AppTextStyles.emptyStateBody,
        ),
      ],
    ),
  );
}

class _MatchView extends StatelessWidget {
  const _MatchView({
    required this.controller,
    required this.matches,
    required this.match,
  });

  final BughouseController controller;
  final BughouseTournamentController matches;
  final StoredBughouseTournament match;

  @override
  Widget build(BuildContext context) {
    final config = match.config;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _OpeningScore(match: match),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                config.openingLabel.isEmpty
                    ? 'From the starting position'
                    : config.openingLabel,
                style: AppTextStyles.caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: AppTextStyles.caption,
                foregroundColor: AppColors.onSurfaceMuted,
              ),
              onPressed: matches.showOpening,
              child: const Text('Show'),
            ),
          ],
        ),
        if (match.status == BughouseTournamentStatus.running) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: match.progress,
            minHeight: 3,
            backgroundColor: AppColors.surfaceInset,
          ),
        ],
        if (match.error != null) ...[
          const SizedBox(height: 8),
          _ErrorBanner(message: match.error!),
        ],
        const SizedBox(height: 14),
        if (matches.openGameNumber != null && matches.isRunning)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: AppTextStyles.caption,
              ),
              icon: const Icon(Icons.sensors, size: 15),
              label: const Text('Follow the game being played'),
              onPressed: matches.followLiveGame,
            ),
          ),
        // Scrolls sideways rather than squeezing: the panel is narrower than
        // the table and the columns after "Result" are the interesting ones.
        Scrollbar(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: 620,
              child: MatchGamesTable(
                whiteHeading: 'A + C (White on 1)',
                blackHeading: 'B + D (Black on 1)',
                selectedNumber: matches.openGameNumber,
                games: [
                  for (final game in match.games)
                    MatchGameRow(
                      number: game.number,
                      round: game.round,
                      white: game.whiteName,
                      black: game.blackName,
                      result: game.result,
                      outcomeLabel: game.outcomeLabel,
                      naturalEnd: game.termination.isNaturalEnd,
                      plies: game.plies,
                      durationMs: game.durationMs,
                    ),
                ],
                onOpenGame: (row) =>
                    matches.openGame(match.games[row.number - 1]),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        BughousePanelSection(
          title: 'Crosstable',
          summary: _crosstableSummary(match),
          children: [
            Scrollbar(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: CrosstableView(
                  participantHeading: 'Team',
                  names: match.config.participantNames,
                  crosstable: buildCrosstable(
                    match.config.participantNames,
                    List<CrosstableGame>.from(
                      match.games.where(
                        (game) => game.result != GameResult.unfinished,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _MatchSettings(match: match),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: AppTextStyles.caption,
              foregroundColor: AppColors.onSurfaceMuted,
            ),
            icon: const Icon(Icons.delete_outline, size: 15),
            label: const Text('Delete this tournament'),
            onPressed: matches.isRunning
                ? null
                : () => matches.delete(match.id),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  static String _crosstableSummary(StoredBughouseTournament match) {
    final names = match.config.participantNames;
    if (names.length < 2) return 'Not enough teams';
    return '${names[0]} vs ${names[1]} · ${match.openingScore.played} finished games';
  }
}

/// The headline: how the side of the *line* scored.
///
/// The biggest thing on the panel, and not the Elo number the crosstable
/// would print. The sampling range sits beside it because 6/10 invites a
/// conclusion ten games cannot support.
class _OpeningScore extends StatelessWidget {
  const _OpeningScore({required this.match});

  final StoredBughouseTournament match;

  @override
  Widget build(BuildContext context) {
    final score = match.openingScore;
    final margin = match.openingScoreMargin;
    final fraction = score.played == 0 ? 0.5 : score.points / score.played;
    final color = score.played == 0
        ? AppColors.onSurfaceMuted
        : fraction > 0.55
        ? AppColors.success
        : fraction < 0.45
        ? AppColors.danger
        : AppColors.evalNeutral;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('WHITE ON BOARD 1 SCORED', style: AppTextStyles.eyebrow),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              match.openingScoreLabel,
              style: AppTextStyles.title.copyWith(color: color),
            ),
            const SizedBox(width: 8),
            if (score.played > 0)
              Expanded(
                child: Text(
                  '${(fraction * 100).toStringAsFixed(0)}%'
                  '  ·  ${score.wins}W ${score.draws}D ${score.losses}L',
                  style: AppTextStyles.muted,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        if (margin != null)
          Tooltip(
            message:
                'Conservative 95% sampling bound for independent games. '
                'Repeated self-play may be correlated; this is not a confidence '
                'interval for the objective strength of the opening.',
            child: Text(
              'Sampling range: ${((fraction - margin).clamp(0, 1) * 100).round()}–'
              '${((fraction + margin).clamp(0, 1) * 100).round()}%',
              style: AppTextStyles.muted,
            ),
          ),
        if (match.gamesPlayed > score.played)
          Text(
            '${match.gamesPlayed - score.played} unfinished games excluded',
            style: AppTextStyles.muted,
          ),
        if (score.draws > 0)
          Text(
            '${match.games.where((g) => g.termination == TerminationReason.maxMoves || g.termination == TerminationReason.mutualSitting).length} draws by move limit or mutual sitting',
            style: AppTextStyles.muted,
          ),
      ],
    );
  }
}

/// What the run was made with — shut, because it is a record rather than a
/// control: everything here was fixed when the run started.
class _MatchSettings extends StatelessWidget {
  const _MatchSettings({required this.match});

  final StoredBughouseTournament match;

  @override
  Widget build(BuildContext context) {
    final config = match.config;
    final variety = config.variety;
    return BughousePanelSection(
      title: 'Settings',
      summary:
          '${config.games} games · ${config.participants.first.budget.label}'
          '${config.alternateSeats ? ' · seats swap' : ' · seats fixed'}',
      children: [
        _Fact('Status', match.status.label),
        for (final participant in config.participants)
          _Fact(participant.name, participant.budget.label),
        _Fact('Clock stance', config.timeStance.label),
        _Fact(
          'Seats',
          config.alternateSeats ? 'Swapped every other game' : 'Fixed',
        ),
        _Fact(
          'Variety',
          variety.isOn
              ? 'First ${variety.plies} plies from the top ${variety.lines}, '
                    'within ${variety.window} of the best'
              : 'Off',
        ),
        _Fact('Ply limit', '${config.maxPlies}, filed as a draw'),
        _Fact('Engine', '${config.hashMb} MB hash · batch ${config.batchSize}'),
        _Fact('Seed', '${config.seed}'),
        // Where `games.bpgn` is — the file `tools/bughouse_db` can index.
        _Fact('Saved in', match.directoryPath),
        if (match.finishedAt != null)
          _Fact(
            'Took',
            formatCompactDuration(
              match.finishedAt!.difference(match.createdAt),
            ),
          ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 96, child: Text(label, style: AppTextStyles.caption)),
        Expanded(child: Text(value, style: AppTextStyles.muted)),
      ],
    ),
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: AppColors.dangerTint,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      message,
      style: AppTextStyles.muted.copyWith(color: AppColors.danger),
    ),
  );
}
