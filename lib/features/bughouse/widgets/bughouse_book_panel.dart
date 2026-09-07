library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_text_styles.dart';
import '../../../widgets/opening_explorer/explorer_move_row.dart';
import '../controllers/bughouse_controller.dart';
import '../services/bughouse_book.dart';
import '../models/bughouse_state.dart';

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
  BughouseBoard _board = BughouseBoard.a;

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('FICS archive', style: AppTextStyles.bodyStrong),
        Text(
          '${formatExplorerCount(book.games)} games · ${status.yearRange}',
          style: AppTextStyles.caption,
        ),
        const SizedBox(height: 8),
        SegmentedButton<BughouseBoard>(
          segments: [
            for (final which in BughouseBoard.values)
              ButtonSegment(value: which, label: Text(which.label)),
          ],
          selected: {_board},
          showSelectedIcon: false,
          onSelectionChanged: (values) {
            if (!mounted) return;
            _controller.clearHover(this);
            setState(() => _board = values.first);
          },
        ),
        const SizedBox(height: 8),
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
    final moves = book.moves.where((move) => move.board == _board).toList();
    final recorded = moves.fold<int>(0, (sum, move) => sum + move.games);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (moves.isEmpty)
          const Text(
            'No recorded continuations on this board.',
            style: AppTextStyles.muted,
          ),
        const ExplorerTableHeader(
          barCaption: 'Your team: Win / Draw / Loss',
          gamesTooltip:
              'Recorded next moves on the selected board, from this two-board position',
        ),
        for (final move in moves.take(BughouseBookPanel.maxRows))
          ExplorerMoveRow(
            // Keyed by the move and the position it belongs to, so a row that
            // changes under the pointer is a new row rather than the old one
            // wearing new numbers.
            key: ValueKey('${book.key}:${move.board}:${move.san}'),
            san: move.san,
            games: move.games,
            wins: oursIsTeamA ? move.teamA : move.teamB,
            draws: move.draws,
            losses: oursIsTeamA ? move.teamB : move.teamA,
            playFraction: recorded == 0 ? 0 : move.games / recorded,
            tooltip: move.averageElo == null
                ? null
                : 'Average rating: ${move.averageElo}',
            onPlay: () => _controller.playBookMove(move),
            onHover: (over) => _onHover(move, over),
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
