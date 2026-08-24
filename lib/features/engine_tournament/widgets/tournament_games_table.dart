/// Every game of a tournament, one row each. Clicking a row opens it in the
/// PGN Viewer — where Prev/Next then walk the whole match, because the
/// tournament's `games.pgn` *is* the collection the viewer loaded.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../models/tournament_game.dart';

class TournamentGamesTable extends StatelessWidget {
  const TournamentGamesTable({
    super.key,
    required this.games,
    required this.onOpenGame,
  });

  final List<TournamentGameRecord> games;
  final void Function(TournamentGameRecord game) onOpenGame;

  @override
  Widget build(BuildContext context) {
    if (games.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No games played yet.', style: AppTextStyles.muted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _GamesHeaderRow(),
        const Divider(height: 1, color: AppColors.divider),
        for (var i = 0; i < games.length; i++)
          _GameRow(
            game: games[i],
            striped: i.isOdd,
            onTap: () => onOpenGame(games[i]),
          ),
      ],
    );
  }
}

const double _kNumberWidth = 44;
const double _kRoundWidth = 44;
const double _kResultWidth = 66;
const double _kPliesWidth = 56;
const double _kTimeWidth = 68;

class _GamesHeaderRow extends StatelessWidget {
  const _GamesHeaderRow();

  @override
  Widget build(BuildContext context) {
    const style = AppTextStyles.caption;
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: _kNumberWidth,
            child: Text('Game', style: style),
          ),
          SizedBox(
            width: _kRoundWidth,
            child: Text('Rd', style: style),
          ),
          Expanded(flex: 3, child: Text('White', style: style)),
          Expanded(flex: 3, child: Text('Black', style: style)),
          SizedBox(
            width: _kResultWidth,
            child: Text('Result', style: style),
          ),
          Expanded(flex: 4, child: Text('Ended', style: style)),
          SizedBox(
            width: _kPliesWidth,
            child: Text('Plies', style: style),
          ),
          SizedBox(
            width: _kTimeWidth,
            child: Text('Time', style: style),
          ),
        ],
      ),
    );
  }
}

class _GameRow extends StatelessWidget {
  const _GameRow({
    required this.game,
    required this.striped,
    required this.onTap,
  });

  final TournamentGameRecord game;
  final bool striped;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final whiteWon = game.result == GameResult.whiteWins;
    final blackWon = game.result == GameResult.blackWins;
    return Material(
      color: striped ? AppColors.rowStripe : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.hoverOverlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            children: [
              SizedBox(
                width: _kNumberWidth,
                child: Text('${game.gameNumber}', style: AppTextStyles.muted),
              ),
              SizedBox(
                width: _kRoundWidth,
                child: Text('${game.round}', style: AppTextStyles.muted),
              ),
              Expanded(
                flex: 3,
                child: _PlayerName(name: game.whiteName, won: whiteWon),
              ),
              Expanded(
                flex: 3,
                child: _PlayerName(name: game.blackName, won: blackWon),
              ),
              SizedBox(
                width: _kResultWidth,
                child: Text(
                  game.result.pgnToken,
                  style: AppTextStyles.bodyStrong.copyWith(
                    color: switch (game.result) {
                      GameResult.whiteWins ||
                      GameResult.blackWins => AppColors.ink,
                      _ => AppColors.onSurfaceMuted,
                    },
                  ),
                ),
              ),
              Expanded(
                flex: 4,
                child: Tooltip(
                  message: game.outcomeLabel,
                  child: Text(
                    game.outcomeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.muted.copyWith(
                      color: game.termination.isNaturalEnd
                          ? AppColors.onSurfaceMuted
                          : AppColors.warningMuted,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: _kPliesWidth,
                child: Text('${game.plies}', style: AppTextStyles.muted),
              ),
              SizedBox(
                width: _kTimeWidth,
                child: Text(
                  _duration(game.durationMs),
                  style: AppTextStyles.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _duration(int ms) {
    final seconds = ms ~/ 1000;
    if (seconds < 60) return '${seconds}s';
    return '${seconds ~/ 60}m ${(seconds % 60).toString().padLeft(2, '0')}s';
  }
}

class _PlayerName extends StatelessWidget {
  const _PlayerName({required this.name, required this.won});

  final String name;
  final bool won;

  @override
  Widget build(BuildContext context) {
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: won
          ? AppTextStyles.bodyStrong.copyWith(color: AppColors.success)
          : AppTextStyles.body,
    );
  }
}
