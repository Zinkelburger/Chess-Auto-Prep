/// The match panel: run a line out, and read what came back.
///
/// The order on the panel is the order of the questions. First **the score of
/// the opening** — how the pair holding White on board 1 did across every
/// game, which is the number you came for and is not the crosstable's number.
/// Then the games, one row each, because in bughouse the interesting output is
/// usually not the score but *what happened*: which board collapsed, what got
/// dropped, whether anyone sat. Clicking a row puts that game on the two
/// boards to the left, which is the reason this lives in the lab and not on a
/// screen of its own.
///
/// The crosstable comes last and stays shut by default. It measures the
/// engines against each other, and in the ordinary case both engines are the
/// same Hivemind — so it is the right table for "does thinking longer help
/// here" and the wrong one for "is this line any good".
library;

import 'package:flutter/material.dart';

import '../../../models/crosstable.dart';
import '../../../models/game_outcome.dart';
import '../../../services/crosstable_builder.dart';
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
            const SizedBox(height: 12),
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

/// New / stop, and which match is on screen.
class _RunBar extends StatelessWidget {
  const _RunBar({required this.controller, required this.matches});

  final BughouseController controller;
  final BughouseTournamentController matches;

  @override
  Widget build(BuildContext context) {
    final running = matches.isRunning;
    return Row(
      children: [
        Expanded(
          child: running
              ? Text(
                  'Playing game ${matches.liveGameNumber}'
                  ' of ${matches.selected?.config.games ?? 0}',
                  style: AppTextStyles.bodyStrong,
                  overflow: TextOverflow.ellipsis,
                )
              : _MatchPicker(matches: matches),
        ),
        const SizedBox(width: 8),
        if (running)
          TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: AppTextStyles.caption,
            ),
            icon: const Icon(Icons.stop, size: 15),
            label: const Text('Stop'),
            onPressed: matches.stop,
          )
        else
          TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: AppTextStyles.caption,
            ),
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text('New match'),
            onPressed: () => showNewBughouseMatchDialog(context, controller),
          ),
      ],
    );
  }
}

/// The saved matches, newest first.
///
/// A dropdown rather than the engine tournament's left rail, because the rail
/// there is a whole column and here the boards have it. The label carries the
/// score, so choosing between two runs of the same line does not need either
/// to be opened.
class _MatchPicker extends StatelessWidget {
  const _MatchPicker({required this.matches});

  final BughouseTournamentController matches;

  @override
  Widget build(BuildContext context) {
    final selected = matches.selected;
    if (selected == null) {
      return const Text('No matches yet', style: AppTextStyles.muted);
    }
    if (matches.matches.length == 1) {
      return Text(
        selected.config.name,
        style: AppTextStyles.bodyStrong,
        overflow: TextOverflow.ellipsis,
      );
    }
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        isDense: true,
        isExpanded: true,
        value: selected.id,
        style: AppTextStyles.body,
        onChanged: (id) {
          if (id != null) matches.select(id);
        },
        items: [
          for (final match in matches.matches)
            DropdownMenuItem(
              value: match.id,
              child: Text(
                '${match.config.name} · ${match.openingScoreLabel}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
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
        Text('Play a line out', style: AppTextStyles.emptyStateTitle),
        SizedBox(height: 8),
        Text(
          'Set the position up on the boards — or just play the first few '
          'moves — then run a match from it. The engine plays both teams, '
          'a dozen times over, and every game lands here to click through.',
          style: AppTextStyles.emptyStateBody,
        ),
        SizedBox(height: 12),
        Text(
          'What comes back is the score of the pair holding White on board 1. '
          'That is the answer to "is this line any good", in the only currency '
          'bughouse has: games.',
          style: AppTextStyles.muted,
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
            const Text(
              'Engine against engine, with the seats swapped every other game '
              'so the opening cancels out. When both teams are the same '
              'Hivemind this measures nothing — read the score above instead.',
              style: AppTextStyles.hint,
            ),
            const SizedBox(height: 8),
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
            label: const Text('Delete this match'),
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
/// Deliberately the biggest thing on the panel, and deliberately not the Elo
/// number the crosstable would print. The margin sits beside it because a
/// score of 6/10 invites a conclusion that ten games cannot support, and the
/// only honest way to say so is to print how wide the interval is.
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
                  ''
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

/// What the match was run with — closed, because it is a record rather than a
/// control: everything here was fixed when the match started.
class _MatchSettings extends StatelessWidget {
  const _MatchSettings({required this.match});

  final StoredBughouseTournament match;

  @override
  Widget build(BuildContext context) {
    final config = match.config;
    final variety = config.variety;
    return BughousePanelSection(
      title: 'How it was run',
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
          config.alternateSeats
              ? 'Swapped every other game'
              : 'Fixed — every game is the same side of the line',
        ),
        _Fact(
          'Variety',
          variety.isOn
              ? 'First ${variety.plies} plies drawn from the engine\'s top '
                    '${variety.lines}, within ${variety.window} of the best'
              : 'Off — every game is the engine\'s single best line',
        ),
        _Fact('Ply limit', '${config.maxPlies}, filed as a draw'),
        _Fact('Engine', '${config.hashMb} MB hash · batch ${config.batchSize}'),
        _Fact('Seed', '${config.seed}'),
        // Where `games.bpgn` is — the file `tools/bughouse_db` can index, and
        // the only thing here another program can read.
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
