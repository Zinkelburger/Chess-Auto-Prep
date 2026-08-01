import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../services/games_library/game_filter.dart';
import '../../../services/games_library/games_library_service.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/common/static_board_thumbnail.dart';
import '../models/recent_game.dart';

/// One recent game, as a card.
///
/// This used to be a seven-column table row, which is the wrong shape for the
/// job: the columns were narrow enough that every cell ellipsized, and a list
/// of "3+0 · me/opp · 1-0" lines is not something you can recognise your own
/// games in. Lichess solves the same problem with a board: the final position,
/// the two players, the opening, and the first few moves. That is what this is
/// — wide enough to read, and tall enough that a handful fit at a time, which
/// is as many games as anyone reviews in one sitting.
///
/// Three things are clickable, and each opens the game at the thing you
/// clicked: the card opens it in the viewer, the mistake counts open its
/// analysis, and the book verdict opens the line you left.
class GameCard extends StatelessWidget {
  const GameCard({
    super.key,
    required this.game,
    required this.onOpen,
    required this.onOpenAnalysis,
    required this.onOpenLine,
  });

  /// Board edge; also sets the card's height.
  ///
  /// 18px squares. The board is here to be *recognised* — "that's the endgame
  /// I lost on time" — and at the sizes a list row wants to be (84, then 108)
  /// the pieces read as smudges, which makes the board cost height and pay
  /// nothing back. This is deliberately larger than a list thumbnail wants to
  /// be, and only here: hover previews and engine boards keep their own sizes.
  /// The sprites are rasterized at 48px, so they stay sharp well past this.
  static const double boardSize = 144;

  final RecentGame game;

  /// Open the game in the PGN viewer (Game tab).
  final VoidCallback onOpen;

  /// Open the game with its engine review (Analysis tab).
  final VoidCallback onOpenAnalysis;

  /// Open the game beside the book line it left (Line tab).
  final VoidCallback onOpenLine;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              // Centred, not top-aligned: the board is taller than the text
              // beside it, and pinning that text to the top left a band of
              // dead space under it on every row.
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildBoard(),
                const SizedBox(width: 10),
                Expanded(child: _buildBody(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBoard() {
    final fen = game.finalFen;
    if (fen == null) {
      return Container(
        width: boardSize,
        height: boardSize,
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.divider),
          borderRadius: BorderRadius.circular(3),
        ),
        child: const Icon(
          Icons.grid_off,
          size: 30,
          color: AppColors.onSurfaceDim,
        ),
      );
    }
    return Tooltip(
      message: 'Final position after ${game.moveCount} moves',
      waitDuration: const Duration(milliseconds: 600),
      // Always from my side of the board — the same orientation I played it in.
      child: StaticBoardThumbnail(
        fen: fen,
        size: boardSize,
        flipped: game.meWhite == false,
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildTopLine(),
        const SizedBox(height: 3),
        _PlayerLine(
          name: game.white,
          elo: game.whiteElo,
          score: game.scorePair.$1,
          isWhitePiece: true,
          isMe: game.meWhite == true,
          outcome: game.myOutcome,
        ),
        _PlayerLine(
          name: game.black,
          elo: game.blackElo,
          score: game.scorePair.$2,
          isWhitePiece: false,
          isMe: game.meWhite == false,
          outcome: game.myOutcome,
        ),
        const SizedBox(height: 3),
        _buildOpeningLine(),
        const SizedBox(height: 2),
        _DeviationLine(game: game, onOpen: onOpenLine),
      ],
    );
  }

  /// Speed, time control, date — plus the two things the review produces
  /// (mistake counts) and the way out to the site.
  Widget _buildTopLine() {
    return Row(
      children: [
        Icon(
          _speedIcon(game.record.speed),
          size: 15,
          color: AppColors.onSurfaceSoft,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            [
              game.timeControlDisplay,
              _speedLabel(game.record.speed),
              game.dateDisplayShort,
            ].join(' · '),
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body.copyWith(
              fontSize: 13,
              color: AppColors.onSurfaceSoft,
            ),
          ),
        ),
        const SizedBox(width: 8),
        MistakeCounts(game: game, onOpen: onOpenAnalysis),
        // Fixed slot, present whether or not the game has a URL: the counts to
        // its left only read as columns if they sit at the same x on every card.
        SizedBox(
          width: 24,
          child: game.gameUrl == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.open_in_new, size: 16),
                  tooltip:
                      'Open in '
                      '${game.platform == GamesPlatform.chesscom ? 'Chess.com' : 'Lichess'}',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 20,
                  ),
                  onPressed: () => launchUrl(Uri.parse(game.gameUrl!)),
                ),
        ),
      ],
    );
  }

  Widget _buildOpeningLine() {
    final opening = game.openingDisplay;
    final moves = game.movesPreview();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (opening != null)
          Text(
            opening,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body.copyWith(
              fontSize: 13,
              color: AppColors.ink,
            ),
          ),
        if (moves.isNotEmpty)
          Text(
            moves,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.mono.copyWith(
              fontSize: 12.5,
              color: AppColors.onSurfaceSoft,
            ),
          ),
      ],
    );
  }

  static IconData _speedIcon(GameSpeed speed) => switch (speed) {
    GameSpeed.ultraBullet || GameSpeed.bullet => Icons.rocket_launch,
    GameSpeed.blitz => Icons.bolt,
    GameSpeed.rapid => Icons.timer,
    GameSpeed.classical => Icons.hourglass_bottom,
    GameSpeed.correspondence => Icons.mail_outline,
    GameSpeed.unknown => Icons.help_outline,
  };

  static String _speedLabel(GameSpeed speed) => switch (speed) {
    GameSpeed.ultraBullet => 'UltraBullet',
    GameSpeed.bullet => 'Bullet',
    GameSpeed.blitz => 'Blitz',
    GameSpeed.rapid => 'Rapid',
    GameSpeed.classical => 'Classical',
    GameSpeed.correspondence => 'Correspondence',
    GameSpeed.unknown => 'Unknown',
  };
}

/// My mistake counts for one game, as three coloured numbers: inaccuracies,
/// mistakes, blunders. A "2 blunders" phrase told you the worst category and
/// hid the rest; "1 2 0" is the whole game at a glance and takes less width.
/// Zero counts stay visible but dim — the columns have to line up between rows
/// for the numbers to be scannable at all.
class MistakeCounts extends StatelessWidget {
  const MistakeCounts({super.key, required this.game, this.onOpen});

  final RecentGame game;

  /// Opens the game's engine review. Null renders the counts as plain text.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final summary = game.summary;
    if (summary == null) {
      return Tooltip(
        message: game.meWhite == null
            ? 'Could not tell which side you played'
            : 'Not reviewed yet — press play to review your games',
        child: Text(
          '— — —',
          style: AppTextStyles.body.copyWith(
            fontSize: 14,
            color: AppColors.onSurfaceMuted,
          ),
        ),
      );
    }
    final counts = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _count(summary.inaccuracies, AppColors.info),
        _count(summary.mistakes, AppColors.warning),
        _count(summary.blunders, AppColors.danger),
      ],
    );
    return Tooltip(
      message: onOpen == null
          ? summary.breakdown
          : '${summary.breakdown}\nClick to open the game analysis.',
      child: onOpen == null
          ? counts
          : InkWell(
              onTap: onOpen,
              borderRadius: BorderRadius.circular(4),
              child: counts,
            ),
    );
  }

  Widget _count(int value, Color color) => SizedBox(
    width: 20,
    child: Text(
      '$value',
      textAlign: TextAlign.center,
      style: AppTextStyles.body.copyWith(
        fontSize: 14,
        fontWeight: value > 0 ? FontWeight.w700 : FontWeight.w400,
        color: value > 0 ? color : AppColors.onSurfaceMuted,
      ),
    ),
  );
}

class _PlayerLine extends StatelessWidget {
  const _PlayerLine({
    required this.name,
    required this.elo,
    required this.score,
    required this.isWhitePiece,
    required this.isMe,
    required this.outcome,
  });

  final String name;
  final String? elo;
  final String score;
  final bool isWhitePiece;
  final bool isMe;
  final MyGameOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final scoreColor = !isMe
        ? AppColors.onSurfaceSoft
        : switch (outcome) {
            MyGameOutcome.win => AppColors.success,
            MyGameOutcome.loss => AppColors.danger,
            MyGameOutcome.draw ||
            MyGameOutcome.unknown => AppColors.onSurfaceSoft,
          };
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: isWhitePiece ? AppColors.ink : AppColors.surface,
            border: Border.all(color: AppColors.outline),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            elo == null ? name : '$name ($elo)',
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body.copyWith(
              fontSize: 14,
              fontWeight: isMe ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          score,
          style: AppTextStyles.body.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: scoreColor,
          ),
        ),
      ],
    );
  }
}

/// What my book says about this game, and the way into it: one line, always
/// present so cards stay the same height.
class _DeviationLine extends StatelessWidget {
  const _DeviationLine({required this.game, required this.onOpen});

  final RecentGame game;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final muted = AppTextStyles.body.copyWith(
      fontSize: 12.5,
      color: AppColors.onSurfaceSoft,
    );
    if (!game.deviationComputed) {
      return Text('Checking your book…', style: muted);
    }
    final report = game.deviation;
    if (report == null) {
      final String message;
      if (game.meWhite == null) {
        message = 'Not your game — no book check';
      } else if (!game.bookDesignated) {
        message = 'No book set for this colour';
      } else {
        message = 'Your book has no usable chapters';
      }
      return Text(message, style: muted);
    }
    if (report.inBook) {
      return Row(
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: 14,
            color: AppColors.successMuted,
          ),
          const SizedBox(width: 4),
          Text(
            'In book · ${report.chapterName}',
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body.copyWith(
              fontSize: 12.5,
              color: AppColors.successMuted,
            ),
          ),
        ],
      );
    }
    final bookEnded = report.bookEnded;
    final byMe = report.byMe == true;
    final color = bookEnded
        ? AppColors.onSurfaceSoft
        : (byMe ? AppColors.warning : AppColors.info);
    final text = bookEnded
        ? 'Book ends at move ${report.moveNumber}'
        : 'Left book at move ${report.moveNumber} '
              '(${byMe ? 'you' : 'them'})';
    return Tooltip(
      message: bookEnded
          ? 'Your prep ends here — ${report.chapterName} has no moves past '
                'this point.\nClick to see the game and the line side by side.'
          : 'Played ${report.playedSan} — book plays '
                '${report.expectedSans.join(' / ')}.\n'
                'Click to see the game and your line side by side.',
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(4),
        child: Row(
          children: [
            Icon(
              bookEnded ? Icons.more_horiz : Icons.fork_right,
              size: 14,
              color: color,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body.copyWith(
                  fontSize: 12.5,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'View line',
              style: AppTextStyles.body.copyWith(
                fontSize: 12.5,
                color: AppColors.info,
                decoration: TextDecoration.underline,
                decorationColor: AppColors.onSurfaceDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
