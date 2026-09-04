/// Every game of a match, one row each. Clicking a row opens that game — in
/// the PGN Viewer for an engine tournament, on the two boards for a bughouse
/// one.
///
/// The row is a view model rather than either feature's own record, because a
/// bughouse game has no White and Black *players*: it has two teams of two,
/// named by the colour they hold on board 1. Everything the table draws is the
/// same in both, so the only honest way to share it is to stop it knowing
/// which kind of game it is showing.
library;

import 'package:flutter/material.dart';

import '../models/game_outcome.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/time_format.dart';

/// One row of the table.
class MatchGameRow {
  const MatchGameRow({
    required this.number,
    required this.round,
    required this.white,
    required this.black,
    required this.result,
    required this.outcomeLabel,
    required this.naturalEnd,
    required this.plies,
    required this.durationMs,
  });

  /// As shown, 1-based.
  final int number;
  final int round;

  /// The participant on each side. In bughouse these are teams: [white] is
  /// the pair holding White on board 1.
  final String white;
  final String black;

  final GameResult result;

  /// How it ended, already spelled out — "Checkmate", "Checkmate — board 2".
  final String outcomeLabel;

  /// Whether that ending was one of the game's own, as opposed to an
  /// adjudication or a failure. Decides the colour of the cell.
  final bool naturalEnd;

  final int plies;
  final int durationMs;
}

class MatchGamesTable extends StatelessWidget {
  const MatchGamesTable({
    super.key,
    required this.games,
    required this.onOpenGame,
    this.whiteHeading = 'White',
    this.blackHeading = 'Black',
    this.selectedNumber,
  });

  final List<MatchGameRow> games;
  final void Function(MatchGameRow game) onOpenGame;

  /// What the two participant columns are called — "White"/"Black" on one
  /// board, the two teams' seats in bughouse.
  final String whiteHeading;
  final String blackHeading;

  /// The row to mark as the one currently open, if any.
  final int? selectedNumber;

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
        _GamesHeaderRow(white: whiteHeading, black: blackHeading),
        const Divider(height: 1, color: AppColors.divider),
        for (var i = 0; i < games.length; i++)
          _GameRow(
            game: games[i],
            striped: i.isOdd,
            selected: games[i].number == selectedNumber,
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
  const _GamesHeaderRow({required this.white, required this.black});

  final String white;
  final String black;

  @override
  Widget build(BuildContext context) {
    const style = AppTextStyles.caption;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const SizedBox(
            width: _kNumberWidth,
            child: Text('Game', style: style),
          ),
          const SizedBox(
            width: _kRoundWidth,
            child: Text('Rd', style: style),
          ),
          Expanded(flex: 3, child: Text(white, style: style)),
          Expanded(flex: 3, child: Text(black, style: style)),
          const SizedBox(
            width: _kResultWidth,
            child: Text('Result', style: style),
          ),
          const Expanded(flex: 4, child: Text('Ended', style: style)),
          const SizedBox(
            width: _kPliesWidth,
            child: Text('Plies', style: style),
          ),
          const SizedBox(
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
    required this.selected,
    required this.onTap,
  });

  final MatchGameRow game;
  final bool striped;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final whiteWon = game.result == GameResult.whiteWins;
    final blackWon = game.result == GameResult.blackWins;
    return Material(
      color: selected
          ? AppColors.surfaceInset
          : striped
          ? AppColors.rowStripe
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.hoverOverlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            children: [
              SizedBox(
                width: _kNumberWidth,
                child: Text('${game.number}', style: AppTextStyles.muted),
              ),
              SizedBox(
                width: _kRoundWidth,
                child: Text('${game.round}', style: AppTextStyles.muted),
              ),
              Expanded(
                flex: 3,
                child: _PlayerName(name: game.white, won: whiteWon),
              ),
              Expanded(
                flex: 3,
                child: _PlayerName(name: game.black, won: blackWon),
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
                      color: game.naturalEnd
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
                  formatCompactDuration(
                    Duration(milliseconds: game.durationMs),
                  ),
                  style: AppTextStyles.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
