import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/game_analysis_controller.dart'
    show MoveClassification;
import '../../../services/games_library/game_filter.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/common/static_board_thumbnail.dart';
import '../models/recent_game.dart';
import '../services/game_moments.dart';
import '../services/game_review_summary.dart';

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
/// analysis, and the book verdict opens the line you left. Those text targets
/// are the only way in. A column of icon buttons on the right edge used to
/// repeat them; it read as clutter on every row and said nothing the words
/// beside it didn't already say.
///
/// Wide cards add two more columns to the right of the text: the review's
/// verdict as three labelled counts — "1 blunder / 2 mistakes / 0
/// inaccuracies" — and a strip of *moments*: the position where the game left
/// the book and each of my mistakes, as small boards with the move drawn on
/// them (see [GameMoment]). The counts used to sit in the top line as three
/// bare digits, and the strip used to take every pixel the window had, so a
/// wide window showed a row of nine boards and a card that was mostly
/// thumbnails. Now the strip is at most [visibleMoments] boards wide and
/// scrolls sideways for the rest; the text column takes what is left, so it
/// is the opening name that gets the room, not a tenth thumbnail.
class GameCard extends StatelessWidget {
  const GameCard({
    super.key,
    required this.game,
    required this.onOpen,
    required this.onOpenAnalysis,
    required this.onOpenLine,
    this.onOpenMoment,
  });

  /// Board edge; also sets the card's height.
  ///
  /// 18px squares. The board is here to be *recognised* — "that's the endgame
  /// I lost on time" — and at the sizes a list row wants to be (84, then 108)
  /// the pieces read as smudges, which makes the board cost height and pay
  /// nothing back. This is deliberately larger than a list thumbnail wants to
  /// be, and only here: hover previews and engine boards keep their own sizes.
  /// Piece sprites are rasterized to fit the square at the display's own
  /// pixel ratio, so this size carries no sharpness ceiling of its own.
  static const double boardSize = 144;

  /// Least width the text column keeps once the other columns appear. It
  /// grows from here: whatever the review block and the strip do not need
  /// goes to the text, which is where a long opening name wants it. Low
  /// enough that a 1280px window with the side panel open still gets two
  /// moments; the player lines fit at this width, the opening name wraps to
  /// an ellipsis either way.
  static const double bodyWidth = 260;

  /// Width of the labelled counts. "0 inaccuracies" and "Not reviewed yet"
  /// both fit on one line at this width.
  static const double reviewWidth = 140;

  /// Board edge of one moment in the strip. Smaller than the final-position
  /// board: this one is not for recognising the position but for seeing the
  /// arrow on it, and the caption under it carries the move. Sized so the
  /// board, two caption lines and the scrollbar fit in [boardSize].
  static const double momentSize = 100;

  /// Gap between two moments in the strip.
  static const double momentGap = 8;

  /// How many moments the strip shows without scrolling. Every card that
  /// has room reserves exactly this width, so the strips line up down the
  /// list; a game with more moments scrolls, one with fewer leaves the
  /// rest of its strip empty.
  static const int visibleMoments = 5;

  /// Width of a full strip: [visibleMoments] boards and the gaps between.
  static const double stripWidth =
      visibleMoments * momentSize + (visibleMoments - 1) * momentGap;

  /// Space between the visual regions of a card. The moment boards are a
  /// second, denser piece of visual information, so they need a little more
  /// separation than the summary needs from the main board.
  static const double _boardBodyGap = 16;
  static const double _columnGap = 24;

  final RecentGame game;

  /// Open the game in the PGN viewer (Game tab).
  final VoidCallback onOpen;

  /// Open the game with its engine review (Analysis tab).
  final VoidCallback onOpenAnalysis;

  /// Open the game beside the book line it left (Line tab).
  final VoidCallback onOpenLine;

  /// Open the game at one of its moments. Null hides the strip.
  final void Function(GameMoment moment)? onOpenMoment;

  static const double _reviewNeeds =
      boardSize + _boardBodyGap + bodyWidth + _columnGap + reviewWidth;

  /// Whether a card [width] wide (inside its padding) has room for the
  /// labelled counts beside the text. Below this the counts fold back into
  /// the top line as three digits.
  static bool reviewFits(double width) => width >= _reviewNeeds;

  /// Whether a card [width] wide has room for the strip as well: the board,
  /// the text at its least width, the counts, and at least one moment.
  static bool stripFits(double width) =>
      width >= _reviewNeeds + _columnGap + momentSize;

  /// How wide the strip is on a card [width] wide: [visibleMoments] boards
  /// when they fit, otherwise as many whole boards as the leftover holds
  /// once the text has its least width. Whole boards, not the leftover
  /// itself: a strip cut through the middle of a board looked broken rather
  /// than scrollable. The slack goes to the text column.
  static double stripWidthFor(double width) {
    final room = width - _reviewNeeds - _columnGap;
    final boards = math.min(
      visibleMoments,
      ((room + momentGap) / (momentSize + momentGap)).floor(),
    );
    return boards * momentSize + (boards - 1) * momentGap;
  }

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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final moments = onOpenMoment == null
                    ? const <GameMoment>[]
                    : game.moments;
                final showReview = reviewFits(width);
                // The strip's column is reserved whenever it fits, moments
                // or not, so the counts sit at the same x on every card. A
                // card with nothing to show there leaves the space empty
                // rather than sliding its counts to the right edge.
                final reserveStrip = onOpenMoment != null && stripFits(width);
                return Row(
                  // Centred, not top-aligned: the board is taller than the
                  // text beside it, and pinning that text to the top left a
                  // band of dead space under it on every row.
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _buildBoard(),
                    const SizedBox(width: _boardBodyGap),
                    Expanded(child: _buildBody(inlineCounts: !showReview)),
                    if (showReview) ...[
                      const SizedBox(width: _columnGap),
                      SizedBox(
                        width: reviewWidth,
                        child: ReviewCounts(game: game, onOpen: onOpenAnalysis),
                      ),
                    ],
                    if (reserveStrip) ...[
                      const SizedBox(width: _columnGap),
                      SizedBox(
                        width: stripWidthFor(width),
                        child: moments.isEmpty
                            ? null
                            : MomentsStrip(
                                moments: moments,
                                flipped: game.meWhite == false,
                                onOpen: onOpenMoment!,
                              ),
                      ),
                    ],
                  ],
                );
              },
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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: StaticBoardThumbnail(
          fen: fen,
          size: boardSize,
          flipped: game.meWhite == false,
        ),
      ),
    );
  }

  /// [inlineCounts] puts the three-digit mistake counts in the top line, for
  /// cards too narrow to carry the labelled block beside the text.
  Widget _buildBody({required bool inlineCounts}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildTopLine(inlineCounts: inlineCounts),
        const SizedBox(height: 3),
        _PlayerLine(
          name: game.white,
          elo: game.whiteElo,
          score: game.scorePair.$1,
          isWhitePiece: true,
          isMe: game.meWhite == true,
        ),
        _PlayerLine(
          name: game.black,
          elo: game.blackElo,
          score: game.scorePair.$2,
          isWhitePiece: false,
          isMe: game.meWhite == false,
        ),
        const SizedBox(height: 3),
        _buildOpeningLine(),
        const SizedBox(height: 2),
        _DeviationLine(game: game, onOpen: onOpenLine),
      ],
    );
  }

  /// Speed, time control, date — and, on a narrow card, the mistake counts.
  Widget _buildTopLine({required bool inlineCounts}) {
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
              game.record.speed.label,
              game.dateDisplayShort,
            ].join(' · '),
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body.copyWith(
              fontSize: 13,
              color: AppColors.onSurfaceSoft,
            ),
          ),
        ),
        if (inlineCounts) ...[
          const SizedBox(width: 8),
          MistakeCounts(game: game, onOpen: onOpenAnalysis),
        ],
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
            style: AppTextStyles.body,
          ),
        if (moves.isNotEmpty)
          Text(
            moves,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.mono.copyWith(
              fontSize: 13,
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
}

/// My mistake counts for one game, as three numbers: inaccuracies, mistakes,
/// blunders. This is the narrow-card form; a card with room shows the same
/// counts with their words ([ReviewCounts]). A "2 blunders" phrase told you
/// the worst category and hid the rest; "1 2 0" is the whole game at a glance
/// and takes less width. Zero counts stay visible but dim — the columns have
/// to line up between rows for the numbers to be scannable at all.
///
/// Severity is carried by hue — blue inaccuracy, amber mistake, red blunder —
/// because those three colours mean exactly that on every chess site the user
/// has ever used, so the column is readable without decoding position. This is
/// the one place in the list where colour is allowed to carry meaning; the
/// scores and the book verdicts beside it stay in one ink. Which number is
/// which is also fixed by position, and spelled out in the tooltip.
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
        _count(summary.inaccuracies, AppColors.mistakeInaccuracy),
        _count(summary.mistakes, AppColors.mistakeMistake),
        _count(summary.blunders, AppColors.mistakeBlunder),
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
        fontWeight: value > 0 ? FontWeight.w600 : FontWeight.w400,
        color: value > 0 ? color : AppColors.onSurfaceDisabled,
      ),
    ),
  );
}

/// The review's verdict, spelled out: "1 blunder / 2 mistakes / 0
/// inaccuracies", worst first, one line each. The three bare digits in the
/// top line were the same information, but they read as a code — you had to
/// know that the order was inaccuracy, mistake, blunder and that the hues
/// said which was which. With the word beside each number nothing needs
/// decoding, and the block is the same height on every card, so a list
/// scans as a column. Rows at zero stay in place, dimmed.
///
/// Severity is still carried by hue — a dot beside each count in the same
/// blue, amber and red the strip's arrows use — because those three colours
/// mean exactly that on every chess site the user has ever used. The words
/// themselves stay in one ink.
class ReviewCounts extends StatelessWidget {
  const ReviewCounts({super.key, required this.game, this.onOpen});

  final RecentGame game;

  /// Opens the game's engine review. Null renders the counts as plain text.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final summary = game.summary;
    if (summary == null) {
      final unknownSide = game.meWhite == null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            unknownSide ? 'Not your game' : 'Not reviewed yet',
            style: AppTextStyles.muted,
          ),
          Text(
            unknownSide
                ? 'Could not tell which side you played'
                : 'Press play to review your games',
            maxLines: 2,
            style: AppTextStyles.caption,
          ),
        ],
      );
    }
    final rows = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _row(summary.blunders, 'blunder', AppColors.mistakeBlunder),
        _row(summary.mistakes, 'mistake', AppColors.mistakeMistake),
        _row(summary.inaccuracies, 'inaccuracy', AppColors.mistakeInaccuracy),
      ],
    );
    return Tooltip(
      message: onOpen == null
          ? summary.breakdown
          : '${summary.breakdown}\nClick to open the game analysis.',
      child: onOpen == null
          ? rows
          : InkWell(
              onTap: onOpen,
              borderRadius: BorderRadius.circular(4),
              child: rows,
            ),
    );
  }

  Widget _row(int count, String word, Color color) {
    final any = count > 0;
    final ink = any ? AppColors.ink : AppColors.onSurfaceDisabled;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: any ? color : AppColors.onSurfaceDisabled,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              GameReviewSummary.counted(count, word),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body.copyWith(
                fontWeight: any ? FontWeight.w600 : FontWeight.w400,
                color: ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerLine extends StatelessWidget {
  const _PlayerLine({
    required this.name,
    required this.elo,
    required this.score,
    required this.isWhitePiece,
    required this.isMe,
  });

  final String name;
  final String? elo;
  final String score;
  final bool isWhitePiece;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    // The score is already the result — "1" and "0" do not need to be green
    // and red as well, and a card that turns red every time you lost is a
    // scoreboard, not a list of games to review. Emphasis marks whose line is
    // mine; the number says how it went.
    final scoreColor = isMe ? AppColors.ink : AppColors.onSurfaceSoft;
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
      fontSize: 13,
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
      } else if (game.sans.isEmpty) {
        message = 'No moves to check';
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
            color: AppColors.onSurfaceSoft,
          ),
          const SizedBox(width: 4),
          Text(
            'In book · ${report.chapterName}',
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
        ],
      );
    }
    final bookEnded = report.bookEnded;
    final byMe = report.byMe == true;
    // One ink for all three verdicts. Amber-for-me / blue-for-them made the
    // card look like it was scoring the game, and the sentence beside the
    // icon already says who left the book and when.
    const color = AppColors.onSurfaceSoft;
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
                style: AppTextStyles.body.copyWith(fontSize: 13, color: color),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'View line',
              style: AppTextStyles.body.copyWith(
                fontSize: 13,
                color: AppColors.onSurfaceMuted,
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

/// The moments of one game as a row of small boards, scrolling sideways.
///
/// Every moment is here, in game order, so scrolling right reads as playing
/// through the game; there is no "+N" and nothing is dropped. What is capped
/// is the *width* — [GameCard.visibleMoments] boards — so the strip never
/// swallows the card. The scrollbar belongs to the strip and stays visible
/// whenever there is more to the right — on a desktop a hidden overflow is
/// the same as a cap. A plain wheel over the
/// strip still scrolls the games list (a horizontal list ignores vertical
/// wheel deltas); a horizontal swipe or the bar moves the strip.
class MomentsStrip extends StatefulWidget {
  const MomentsStrip({
    super.key,
    required this.moments,
    required this.flipped,
    required this.onOpen,
  });

  final List<GameMoment> moments;

  /// Black at the bottom — the same orientation as the final-position board.
  final bool flipped;
  final void Function(GameMoment moment) onOpen;

  @override
  State<MomentsStrip> createState() => _MomentsStripState();
}

class _MomentsStripState extends State<MomentsStrip> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: GameCard.boardSize,
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        thickness: 4,
        child: ListView.separated(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 8),
          itemCount: widget.moments.length,
          separatorBuilder: (_, _) => const SizedBox(width: GameCard.momentGap),
          itemBuilder: (context, index) {
            final moment = widget.moments[index];
            return MomentTile(
              moment: moment,
              flipped: widget.flipped,
              onTap: () => widget.onOpen(moment),
            );
          },
        ),
      ),
    );
  }
}

/// One moment: the board with the move on it, the move, and what it was.
///
/// The played move takes the mistake's hue — blue, amber, red, the same three
/// the counts use — or red when I left the book and a plain ink when they
/// did or when the book simply ended there. What the book or the engine
/// wanted instead is green. Those are the only colours in the strip; the
/// captions stay in the two inks.
class MomentTile extends StatelessWidget {
  const MomentTile({
    super.key,
    required this.moment,
    required this.flipped,
    required this.onTap,
  });

  final GameMoment moment;
  final bool flipped;
  final VoidCallback onTap;

  static Color _playedColor(GameMoment moment) =>
      switch (moment.classification) {
        MoveClassification.blunder => AppColors.mistakeBlunder,
        MoveClassification.mistake => AppColors.mistakeMistake,
        MoveClassification.inaccuracy => AppColors.mistakeInaccuracy,
        _ =>
          moment.byMe && !moment.bookEnd
              ? AppColors.danger
              : AppColors.onSurfaceMuted,
      };

  @override
  Widget build(BuildContext context) {
    final arrows = <BoardArrow>[
      for (final uci in moment.wantedUcis)
        BoardArrow(uci: uci, color: AppColors.success.withValues(alpha: 0.85)),
      if (moment.playedUci.isNotEmpty)
        BoardArrow(
          uci: moment.playedUci,
          color: _playedColor(moment).withValues(alpha: 0.9),
        ),
    ];
    return Tooltip(
      message: moment.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: GameCard.momentSize,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: StaticBoardThumbnail(
                  fen: moment.fen,
                  size: GameCard.momentSize,
                  flipped: flipped,
                  arrows: arrows,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                moment.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.monoDense.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                moment.detail,
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
