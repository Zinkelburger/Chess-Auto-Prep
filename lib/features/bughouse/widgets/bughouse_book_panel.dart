/// What four thousand people actually played from here.
///
/// The engine's two blocks above this one say what is *good*; this one says
/// what is *played*, out of 3.6 million FICS games. In bughouse that gap is
/// wider than it is in chess — the archive is blitz played by four people at
/// once, so a line the engine dislikes can still be the one you have to be
/// ready for, and a line it loves can be one nobody has ever tried on you.
///
/// It is the same table as the Lichess opening explorer elsewhere in the app
/// ([ExplorerMoveRow] and friends), with the FICS book as its data source and
/// a seat letter before each move, because four people play. Like the lab's
/// other reference blocks it starts shut, with its one-line summary showing;
/// the engine pane above is what you look at while thinking.
///
/// The panel is silent on a machine with no book, which is the normal case:
/// see [BughouseBook.open].
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_text_styles.dart';
import '../../../widgets/opening_explorer/explorer_move_row.dart';
import '../controllers/bughouse_controller.dart';
import '../services/bughouse_book.dart';
import 'bughouse_panel_section.dart';

class BughouseBookPanel extends StatefulWidget {
  const BughouseBookPanel({super.key, required this.controller});

  final BughouseController controller;

  /// How many continuations are listed — the Lichess explorer's own default.
  ///
  /// Two boards means twice the branching, so the opening position alone has
  /// forty recorded continuations and thirty of them round to 0%. The Σ row
  /// still counts every game, listed or not.
  static const maxRows = 12;

  @override
  State<BughouseBookPanel> createState() => _BughouseBookPanelState();
}

class _BughouseBookPanelState extends State<BughouseBookPanel> {
  BughouseController get _controller => widget.controller;

  /// The row under the pointer, so the exit of *that* row is what clears the
  /// boards — a row rebuilt away while lit clears itself on dispose, and by
  /// then another row may already be drawing.
  BughouseBookMove? _hovered;

  void _onHover(BughouseBookMove move, bool over) {
    if (over) {
      _hovered = move;
      _controller.hoverBookMove(move, owner: this);
    } else if (identical(_hovered, move)) {
      _hovered = null;
      _controller.clearHover(this);
    }
  }

  @override
  void dispose() {
    if (_hovered != null && !_controller.isDisposed) {
      _controller.clearHover(this);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _controller.bookStatus;
    final book = _controller.bookPosition;
    if (status == null || book == null) return const SizedBox.shrink();

    return BughousePanelSection(
      title: 'FICS ARCHIVE',
      summary: book.games == 0
          ? _nothing(status)
          : '${formatExplorerCount(book.games)} games here · '
                '${status.yearRange}',
      padding: EdgeInsets.zero,
      children: [
        if (book.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
            child: Text(
              book.games > 0
                  ? 'No continuations meet the archive minimum of ${status.minGames} games, or this is the end of the indexed line.'
                  : _nothing(status),
              style: AppTextStyles.muted,
            ),
          )
        else
          _table(book),
      ],
    );
  }

  Widget _table(BughouseBookPosition book) {
    final state = _controller.state;
    // Everything on this panel is read from our seat, the way the eval above
    // it is. The book counts for the pair holding White on board A, which is
    // us exactly when our team plays White there.
    final oursIsTeamA = state.team == Side.white;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ExplorerTableHeader(
          barCaption: 'Win / Draw / Loss',
          gamesTooltip:
              'Games in which the move was played, and its share of every '
              'archived game from this position',
        ),
        for (final move in book.moves.take(BughouseBookPanel.maxRows))
          ExplorerMoveRow(
            // Keyed by the move and the position it belongs to, so a row that
            // changes under the pointer is a new row rather than the old one
            // wearing new numbers.
            key: ValueKey('${book.key}:${move.board}:${move.san}'),
            seat: state.seatLetter(move.board, move.mover),
            san: move.san,
            games: move.games,
            wins: oursIsTeamA ? move.teamA : move.teamB,
            draws: move.draws,
            losses: oursIsTeamA ? move.teamB : move.teamA,
            playFraction: book.games == 0 ? 0 : move.games / book.games,
            tooltip: move.averageElo == null
                ? null
                : 'Average rating: ${move.averageElo}',
            onPlay: () => _controller.playBookMove(move),
            onHover: (over) => _onHover(move, over),
          ),
        ExplorerTotalsRow(
          games: book.games,
          wins: oursIsTeamA ? book.teamA : book.teamB,
          draws: book.draws,
          losses: oursIsTeamA ? book.teamB : book.teamA,
        ),
      ],
    );
  }

  /// Why there is nothing to show, which is two different things.
  String _nothing(BughouseBookStatus status) {
    final ply = _controller.history.cursor;
    if (ply >= status.maxPly) {
      return 'Past the archive, which is indexed to ${status.maxPly} plies.';
    }
    return 'No archived game reached this position.';
  }
}
