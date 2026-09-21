import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../chess/pgn/tree_edit.dart';
import '../ui/theme.dart';

/// A board showing one position, and the way a move is played on it.
///
/// Lichess's board does the drawing and the pointer work: click a piece then
/// its destination, or drag it there; only legal moves leave the board, and
/// a pawn reaching the last rank waits for the piece it becomes. This widget
/// turns the document's position into what the board needs, keeps the
/// board's controller, and hands the move it makes to [onMove] as UCI. How
/// the board looks is [BoardTheme.settings].
class BoardView extends StatefulWidget {
  const BoardView({
    super.key,
    required this.fen,
    required this.orientation,
    required this.onMove,
    this.lastMove,
    this.coordinates = true,
  });

  final Fen fen;

  /// Whether the rank and file letters are drawn.
  final bool coordinates;

  /// The side shown at the bottom.
  final Side orientation;

  final void Function(String uci) onMove;

  /// The move just played, as UCI, for the highlight; null at the start.
  final String? lastMove;

  @override
  State<BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends State<BoardView> {
  final _controller = ChessboardController(game: _noPosition);

  @override
  void initState() {
    super.initState();
    _controller.updatePosition(
      gameOf(widget.fen, widget.lastMove),
      animate: false,
    );
  }

  @override
  void didUpdateWidget(BoardView old) {
    super.didUpdateWidget(old);
    if (old.fen != widget.fen || old.lastMove != widget.lastMove) {
      _controller.updatePosition(gameOf(widget.fen, widget.lastMove));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = BoardTheme.of(
      context,
    ).settings(coordinates: widget.coordinates);
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) => Chessboard(
          size: constraints.maxWidth,
          controller: _controller,
          orientation: widget.orientation,
          settings: settings,
          onMove: (move, {viaDragAndDrop}) => widget.onMove(move.uci),
        ),
      ),
    );
  }
}

/// A board with nothing on it and nobody to move, which is what a position
/// the board cannot read is shown as.
///
/// Letting a FEN exception out of `initState` would take the whole frame
/// down and with it every pointer this app has, which looks to the user like
/// a dead mouse rather than one bad position.
const _noPosition = GameData(
  fen: kEmptyBoardFEN,
  playerSide: PlayerSide.none,
  sideToMove: Side.white,
  validMoves: {},
);

/// What the board needs to show [fen] and let either side move on it:
/// the pieces, whose move it is, every legal move, the last move and the
/// king in check.
GameData gameOf(Fen fen, String? lastMove) {
  final position = positionOf(fen);
  if (position == null) return _noPosition;
  return GameData(
    fen: fen.value,
    playerSide: PlayerSide.both,
    sideToMove: position.turn,
    validMoves: makeLegalMoves(position),
    lastMove: lastMove == null ? null : Move.parse(lastMove),
    kingSquareInCheck: position.isCheck
        ? position.board.kingOf(position.turn)
        : null,
  );
}
