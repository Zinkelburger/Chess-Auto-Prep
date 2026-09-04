/// What four thousand people actually played from here.
///
/// The engine's two blocks above this one say what is *good*; this one says
/// what is *played*, out of 3.6 million FICS games. In bughouse that gap is
/// wider than it is in chess — the archive is blitz played by four people at
/// once, so a line the engine dislikes can still be the one you have to be
/// ready for, and a line it loves can be one nobody has ever tried on you.
///
/// The panel is silent on a machine with no book, which is the normal case:
/// see [BughouseBook.open].
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../controllers/bughouse_controller.dart';
import '../services/bughouse_book.dart';

class BughouseBookPanel extends StatelessWidget {
  const BughouseBookPanel({super.key, required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final status = controller.bookStatus;
    final book = controller.bookPosition;
    if (status == null || book == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('FICS ARCHIVE', style: AppTextStyles.eyebrow),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message:
                    '${_full(status.games)} bughouse games from '
                    '${status.yearRange}, indexed to ${status.maxPly} plies.\n'
                    'Continuations played fewer than ${status.minGames} times '
                    'are not listed.',
                child: Text(
                  book.isEmpty
                      ? status.yearRange
                      : '${_full(book.games)} games here',
                  style: AppTextStyles.caption,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (book.isEmpty)
          Text(_nothing(status), style: AppTextStyles.muted)
        else ...[
          for (final move in book.moves.take(_maxRows))
            _BookRow(
              // Keyed by the move and the position it belongs to, so a row
              // that changes under the pointer is a new row rather than the
              // old one wearing new numbers.
              key: ValueKey('${book.key}:${move.board}:${move.san}'),
              controller: controller,
              move: move,
              total: book.games,
            ),
          if (book.moves.length > _maxRows)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 3),
              child: Text(_tail(book), style: AppTextStyles.muted),
            ),
        ],
      ],
    );
  }

  /// How many continuations are listed before the tail is rolled up.
  ///
  /// Two boards means twice the branching, so the opening position alone has
  /// forty recorded continuations and thirty of them round to 0%. A reader
  /// preparing a line needs the ones that get played; the rest are a scroll
  /// between them and the controls below.
  static const _maxRows = 12;

  /// The one line that stands for everything not listed. It bounds the largest
  /// of them, so "more" is a quantity rather than a shrug — and a bound, not a
  /// measurement, so a tail of tenths of a percent reads "none above 1%"
  /// rather than the useless "none above <1%".
  String _tail(BughouseBookPosition book) {
    final hidden = book.moves.length - _maxRows;
    final largest = book.moves[_maxRows];
    final percent = book.games == 0 ? 0.0 : 100 * largest.games / book.games;
    final bound = percent < 1 ? 1 : percent.ceil();
    return '+$hidden more, none above $bound%.';
  }

  /// Why there is nothing to show, which is two different things.
  String _nothing(BughouseBookStatus status) {
    final ply = controller.history.cursor;
    if (ply >= status.maxPly) {
      return 'Past the archive — it is indexed to ${status.maxPly} plies '
          'across both boards.';
    }
    return 'No archived game reached this position.';
  }
}

/// One continuation: who played it, how often, and how it went for us.
///
/// Stateful for the same single bit as an engine line row — whether the
/// pointer is over it — because the boards' highlight follows the pointer and
/// a row unmounted while lit has to clear its own highlight and nobody else's.
class _BookRow extends StatefulWidget {
  const _BookRow({
    super.key,
    required this.controller,
    required this.move,
    required this.total,
  });

  final BughouseController controller;
  final BughouseBookMove move;

  /// Games through the parent position, the denominator of the play rate.
  final int total;

  @override
  State<_BookRow> createState() => _BookRowState();
}

class _BookRowState extends State<_BookRow> {
  bool _lit = false;

  BughouseController get _controller => widget.controller;

  void _enter() {
    setState(() => _lit = true);
    _controller.hoverBookMove(widget.move, owner: this);
  }

  void _exit() {
    setState(() => _lit = false);
    _controller.clearHover(this);
  }

  @override
  void dispose() {
    if (_lit) {
      final controller = _controller;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!controller.isDisposed) controller.clearHover(this);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final move = widget.move;
    final state = _controller.state;
    // Everything on this panel is read from our seat, the way the eval above
    // it is. The book counts for the pair holding White on board A, which is
    // us exactly when our team plays White there.
    final oursIsTeamA = state.team == Side.white;
    final wins = oursIsTeamA ? move.teamA : move.teamB;
    final losses = oursIsTeamA ? move.teamB : move.teamA;
    final score = oursIsTeamA ? move.teamAScore : 1 - move.teamAScore;
    final rate = widget.total == 0 ? 0.0 : move.games / widget.total;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _enter(),
      onExit: (_) => _exit(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _controller.playBookMove(move),
        child: Tooltip(
          message: _tooltip(move, wins: wins, losses: losses, score: score),
          waitDuration: const Duration(milliseconds: 400),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            decoration: BoxDecoration(
              color: _lit ? AppColors.hoverOverlay : Colors.transparent,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Row(
              children: [
                // The seat letter, not the board's: four people play, and the
                // panel above names them A, B, C and D throughout.
                SizedBox(
                  width: 14,
                  child: Text(
                    state.seatLetter(move.board, move.mover),
                    style: AppTextStyles.monoDense.copyWith(
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    move.san,
                    style: AppTextStyles.mono.copyWith(color: AppColors.ink),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(
                  width: 46,
                  child: Text(
                    _compact(move.games),
                    textAlign: TextAlign.right,
                    style: AppTextStyles.monoDense.copyWith(
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 30,
                  child: Text(
                    _share(rate),
                    textAlign: TextAlign.right,
                    style: AppTextStyles.monoDense.copyWith(
                      color: AppColors.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _ScoreBar(wins: wins, draws: move.draws, losses: losses),
                const SizedBox(width: 8),
                SizedBox(
                  width: 30,
                  child: Text(
                    move.averageElo == null ? '—' : '${move.averageElo}',
                    textAlign: TextAlign.right,
                    style: AppTextStyles.monoDense.copyWith(
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _tooltip(
    BughouseBookMove move, {
    required int wins,
    required int losses,
    required double score,
  }) {
    final lines = [
      '${move.san} — ${_full(move.games)} games',
      'We score ${(score * 100).toStringAsFixed(1)}%: '
          '${_full(wins)} won, ${_full(move.draws)} drawn, '
          '${_full(losses)} lost',
      if (move.unknown > 0)
        '${_full(move.unknown)} unfinished (aborted or disconnected), '
            'left out of the bar',
      'Average ${move.averageElo ?? '—'}, best ${move.maxElo} '
          '(game ${move.topGameNo}) · last played ${move.lastYear}',
    ];
    return lines.join('\n');
  }
}

/// Wins, draws and losses over the games that finished — ours on the left,
/// because everything else on this panel is read from our seat too.
class _ScoreBar extends StatelessWidget {
  const _ScoreBar({
    required this.wins,
    required this.draws,
    required this.losses,
  });

  final int wins;
  final int draws;
  final int losses;

  @override
  Widget build(BuildContext context) {
    final decided = wins + draws + losses;
    if (decided == 0) {
      return const SizedBox(width: 56, height: 8);
    }
    return SizedBox(
      width: 56,
      height: 8,
      child: Row(
        children: [
          if (wins > 0)
            Expanded(
              flex: wins,
              child: Container(color: AppColors.wdlWhite),
            ),
          if (draws > 0)
            Expanded(
              flex: draws,
              child: Container(color: AppColors.wdlDraw),
            ),
          if (losses > 0)
            Expanded(
              flex: losses,
              child: Container(color: AppColors.wdlBlack),
            ),
        ],
      ),
    );
  }
}

/// A play rate. Rounds, but never to `0%`: a move in the book was played, and
/// a zero beside a four-figure game count reads as a broken column rather than
/// as a rare line.
String _share(double rate) {
  final percent = rate * 100;
  if (percent > 0 && percent < 0.5) return '<1%';
  return '${percent.round()}%';
}

/// `1.6M`, `968k`, `47` — a column two digits wide has to say a million.
String _compact(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 10000) return '${(n / 1000).round()}k';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

/// `1,610,924` — for a tooltip, which has room for the real number.
String _full(int n) {
  final digits = n.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
