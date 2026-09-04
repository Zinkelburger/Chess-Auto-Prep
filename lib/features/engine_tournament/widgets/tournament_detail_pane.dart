/// One tournament in full: what it is, how it is going, the crosstable, and
/// every game.
library;

import 'package:flutter/material.dart';

import '../../../constants/chess_constants.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../models/game_outcome.dart';
import '../../../utils/app_messages.dart';
import '../../../widgets/common/static_board_thumbnail.dart';
import '../controllers/engine_tournament_controller.dart';
import '../models/stored_tournament.dart';
import '../models/tournament_config.dart';
import '../models/tournament_game.dart';
import '../../../widgets/crosstable_view.dart';
import '../../../widgets/match_games_table.dart';
import 'tournament_list_pane.dart' show TournamentStatusChip;

class TournamentDetailPane extends StatelessWidget {
  const TournamentDetailPane({
    super.key,
    required this.controller,
    required this.tournament,
    required this.onOpenGame,
    required this.onOpenAllGames,
    required this.onDelete,
    required this.onRerun,
  });

  final EngineTournamentController controller;
  final StoredTournament tournament;
  final void Function(TournamentGameRecord game) onOpenGame;
  final VoidCallback onOpenAllGames;
  final VoidCallback onDelete;
  final VoidCallback onRerun;

  @override
  Widget build(BuildContext context) {
    final config = tournament.config;
    final running = controller.isRunningTournament(tournament.id);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _Header(
          tournament: tournament,
          running: running,
          onOpenAllGames: onOpenAllGames,
          onDelete: onDelete,
          onRerun: onRerun,
          onStop: controller.cancelRun,
        ),
        const SizedBox(height: 14),
        if (running) ...[
          _LivePanel(controller: controller, config: config),
          const SizedBox(height: 14),
        ],
        if (tournament.error != null) ...[
          _ErrorBanner(message: tournament.error!),
          const SizedBox(height: 14),
        ],
        _PanelCard(
          title: 'Crosstable',
          child: controller.crosstable == null
              ? const SizedBox.shrink()
              : CrosstableView(
                  crosstable: controller.crosstable!,
                  names: [for (final e in config.engines) e.name],
                ),
        ),
        const SizedBox(height: 14),
        _PanelCard(
          title: 'Games',
          trailing: TextButton.icon(
            onPressed: tournament.games.isEmpty ? null : onOpenAllGames,
            icon: const Icon(Icons.menu_book, size: 16),
            label: const Text('Open in PGN Viewer'),
          ),
          child: MatchGamesTable(
            games: [
              for (final game in tournament.games)
                MatchGameRow(
                  number: game.gameNumber,
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
            onOpenGame: (row) => onOpenGame(tournament.games[row.number - 1]),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.tournament,
    required this.running,
    required this.onOpenAllGames,
    required this.onDelete,
    required this.onRerun,
    required this.onStop,
  });

  final StoredTournament tournament;
  final bool running;
  final VoidCallback onOpenAllGames;
  final VoidCallback onDelete;
  final VoidCallback onRerun;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final config = tournament.config;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: 'Copy the starting FEN',
          child: InkWell(
            onTap: () => copyToClipboard(
              context,
              config.startFen,
              successMessage: 'Starting FEN copied.',
            ),
            child: StaticBoardThumbnail(fen: config.startFen, size: 92),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      config.name,
                      style: AppTextStyles.title,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TournamentStatusChip(
                    status: tournament.status,
                    running: running,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _MetaChip(
                    icon: Icons.timer_outlined,
                    label: config.timeControl.label,
                  ),
                  _MetaChip(
                    icon: Icons.format_list_numbered,
                    label:
                        '${tournament.gamesPlayed}/${tournament.gamesTotal} games',
                  ),
                  if (config.engines.length > 2)
                    _MetaChip(
                      icon: Icons.account_tree_outlined,
                      label: config.format.label,
                    ),
                  if (config.concurrency > 1)
                    _MetaChip(
                      icon: Icons.dynamic_feed,
                      label: '${config.concurrency} at once',
                    ),
                  _MetaChip(
                    icon: Icons.grid_view,
                    label: config.startsFromStandardPosition
                        ? 'Standard start'
                        : config.openingLabel.isNotEmpty
                        ? config.openingLabel
                        : 'From position',
                    tooltip: '${config.startFen}\n\nClick to copy this FEN.',
                    onTap: () => copyToClipboard(
                      context,
                      config.startFen,
                      successMessage: 'Starting FEN copied.',
                    ),
                  ),
                  if (config.adjudication.drawEnabled ||
                      config.adjudication.resignEnabled)
                    _MetaChip(
                      icon: Icons.gavel,
                      label: 'Adjudicated',
                      tooltip: _adjudicationSummary(config),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  if (running)
                    FilledButton.tonalIcon(
                      onPressed: onStop,
                      icon: const Icon(Icons.stop, size: 16),
                      label: const Text('Stop'),
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: onRerun,
                      icon: const Icon(Icons.replay, size: 16),
                      label: const Text('Run again'),
                    ),
                  OutlinedButton.icon(
                    onPressed: tournament.games.isEmpty ? null : onOpenAllGames,
                    icon: const Icon(Icons.menu_book, size: 16),
                    label: const Text('Browse games'),
                  ),
                  if (!running)
                    TextButton.icon(
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('Delete'),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(tournament.pgnPath, style: AppTextStyles.caption),
            ],
          ),
        ),
      ],
    );
  }

  static String _adjudicationSummary(TournamentConfig config) {
    final rules = config.adjudication;
    final parts = <String>[];
    if (rules.drawEnabled) {
      parts.add(
        'Draw when both engines stay within ${rules.drawScoreCp}cp of zero '
        'for ${rules.drawMoveCount} moves, from move ${rules.drawMoveNumber}.',
      );
    }
    if (rules.resignEnabled) {
      parts.add(
        'Resign when a side is ${rules.resignScoreCp}cp down for '
        '${rules.resignMoveCount} moves'
        '${rules.twoSidedResign ? ' and its opponent agrees' : ''}.',
      );
    }
    parts.add('Hard stop at ${rules.maxMoves} moves.');
    return parts.join('\n');
  }
}

/// The game in progress: the board, the last move, and how far along we are.
class _LivePanel extends StatelessWidget {
  const _LivePanel({required this.controller, required this.config});

  final EngineTournamentController controller;
  final TournamentConfig config;

  @override
  Widget build(BuildContext context) {
    final tournament = controller.selected;
    return _PanelCard(
      title: 'Now playing',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StaticBoardThumbnail(
              fen: controller.liveFen ?? config.startFen,
              size: 160,
              flipped: false,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    controller.liveStatus.isEmpty
                        ? 'Starting…'
                        : controller.liveStatus,
                    style: AppTextStyles.bodyStrong,
                  ),
                  if (controller.liveBackgroundGames > 0) ...[
                    const SizedBox(height: 3),
                    Text(
                      '+${controller.liveBackgroundGames} more running '
                      'alongside this one',
                      style: AppTextStyles.hint,
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    controller.liveMoveLabel.isEmpty
                        ? 'Waiting for the first move…'
                        : controller.liveMoveLabel,
                    style: AppTextStyles.body.copyWith(
                      fontFamily: AppTextStyles.monoFamily,
                      color: AppColors.onSurfaceSoft,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => copyToClipboard(
                        context,
                        controller.liveFen ?? config.startFen,
                        successMessage: 'Position FEN copied.',
                      ),
                      icon: const Icon(Icons.copy, size: 14),
                      label: const Text('Copy FEN'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (tournament != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: tournament.progress,
                        minHeight: 4,
                        backgroundColor: AppColors.surfaceInset,
                      ),
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

class _PanelCard extends StatelessWidget {
  const _PanelCard({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: [
                Text(
                  title,
                  style: AppTextStyles.bodyStrong.copyWith(
                    color: AppColors.onSurfaceSoft,
                  ),
                ),
                const Spacer(),
                ?trailing,
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.divider),
          child,
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.icon,
    required this.label,
    this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? tooltip;

  /// When set, the chip becomes a button (used for copy-the-FEN).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Widget chip = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.onSurfaceDim),
          const SizedBox(width: 5),
          Text(label, style: AppTextStyles.caption),
          if (onTap != null) ...[
            const SizedBox(width: 5),
            const Icon(Icons.copy, size: 12, color: AppColors.onSurfaceDim),
          ],
        ],
      ),
    );
    final tappable = onTap == null
        ? chip
        : InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(4),
            child: chip,
          );
    return tooltip == null
        ? tappable
        : Tooltip(message: tooltip!, child: tappable);
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.dangerTint,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
          const SizedBox(width: 10),
          Expanded(child: SelectableText(message, style: AppTextStyles.body)),
        ],
      ),
    );
  }
}

/// Shown when nothing has been run yet.
class TournamentEmptyState extends StatelessWidget {
  const TournamentEmptyState({super.key, required this.onNew});

  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const StaticBoardThumbnail(fen: kStandardStartFen, size: 120),
            const SizedBox(height: 18),
            const Text('No tournaments yet', style: AppTextStyles.title),
            const SizedBox(height: 8),
            const Text(
              'Put two engines in a position and let them settle it. Games '
              'are saved as ordinary PGN, so the whole match opens in the '
              'PGN Viewer when it is done.',
              textAlign: TextAlign.center,
              style: AppTextStyles.hint,
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onNew,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New tournament'),
            ),
          ],
        ),
      ),
    );
  }
}
