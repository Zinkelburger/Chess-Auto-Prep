import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chess/fen.dart';
import '../chess/pgn/board_shapes.dart';
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
///
/// A right-drag draws an arrow and a right-click a circle, as on Lichess:
/// green, or red with Shift, blue with Alt, yellow with Ctrl. What is drawn
/// goes to [onDraw] when the board has somewhere to keep it; otherwise it
/// stays on this board until the position changes or the left button is
/// pressed on it.
class BoardView extends StatefulWidget {
  const BoardView({
    super.key,
    required this.fen,
    required this.orientation,
    required this.onMove,
    this.lastMove,
    this.coordinates = true,
    this.movable = true,
    this.shapes = const [],
    this.onDraw,
  });

  final Fen fen;

  /// Whether the rank and file letters are drawn.
  final bool coordinates;

  /// The side shown at the bottom.
  final Side orientation;

  final void Function(String uci) onMove;

  /// The move just played, as UCI, for the highlight; null at the start.
  final String? lastMove;

  /// Whether a piece may be moved; the position is shown either way.
  final bool movable;

  /// The arrows and circles someone else keeps: the move's comment, the
  /// engine's threat.
  final List<BoardShape> shapes;

  /// Where a shape the user draws goes; null keeps it on this board alone.
  final ValueChanged<BoardShape>? onDraw;

  @override
  State<BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends State<BoardView> {
  final _controller = ChessboardController(game: _noPosition);

  /// Shapes drawn with nowhere to keep them, gone with the position.
  List<BoardShape> _drawn = const [];

  /// The shape under a right-drag in progress, drawn as it goes.
  BoardShape? _drawing;

  @override
  void initState() {
    super.initState();
    _controller.updatePosition(
      gameOf(widget.fen, widget.lastMove, movable: widget.movable),
      animate: false,
    );
  }

  @override
  void didUpdateWidget(BoardView old) {
    super.didUpdateWidget(old);
    if (old.fen != widget.fen) {
      _drawn = const [];
      _drawing = null;
      // Clear package-owned selection/drag state before replacing a position,
      // even when the new position has the same side to move. Keeping the old
      // FEN here preserves the animation into the new position below.
      _controller.updatePosition(gameOf(old.fen, old.lastMove, movable: false));
    }
    if (old.fen != widget.fen ||
        old.lastMove != widget.lastMove ||
        old.movable != widget.movable) {
      _controller.updatePosition(
        gameOf(widget.fen, widget.lastMove, movable: widget.movable),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BoardTheme.of(context);
    final base = theme.settings(coordinates: widget.coordinates);
    // chessground has no public selection callback. Keep this read-only
    // painter bridge here so hints follow its actual tap/drag/cancel state.
    // ignore: invalid_use_of_internal_member
    final selection = _controller.highlightNotifier;
    ChessboardBackground hints(ChessboardBackground background) =>
        _LegalMoveBackground(
          background: background,
          controller: _controller,
          selection: selection,
          side: widget.orientation,
          color: theme.validMove,
        );
    final colors = base.colorScheme;
    final settings = base.copyWith(
      colorScheme: colors.copyWith(
        background: hints(colors.background),
        whiteCoordBackground: hints(colors.whiteCoordBackground),
        blackCoordBackground: hints(colors.blackCoordBackground),
      ),
    );
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) => Listener(
          onPointerDown: (event) => _down(event, constraints.maxWidth),
          onPointerMove: (event) => _move(event, constraints.maxWidth),
          onPointerUp: (_) => _up(),
          onPointerCancel: (_) => _cancel(),
          child: Chessboard(
            size: constraints.maxWidth,
            controller: _controller,
            orientation: widget.orientation,
            settings: settings,
            shapes: {
              for (final shape in [...widget.shapes, ..._drawn, ?_drawing])
                _shapeOf(shape),
            },
            onMove: (move, {viaDragAndDrop}) {
              if (!mounted) return;
              widget.onMove(move.uci);
            },
          ),
        ),
      ),
    );
  }

  /// The right button starts a shape on the square under it; the left one
  /// wipes what was drawn with nowhere to keep it, as a click does on
  /// Lichess, and then plays on as usual.
  void _down(PointerDownEvent event, double size) {
    if (event.buttons == kSecondaryButton) {
      final square = squareAt(event.localPosition, size, widget.orientation);
      if (square == null) return;
      setState(() => _drawing = BoardShape.circle(square, _heldColour()));
    } else if (event.buttons == kPrimaryButton && _drawn.isNotEmpty) {
      setState(() => _drawn = const []);
    }
  }

  void _move(PointerMoveEvent event, double size) {
    final drawing = _drawing;
    final square = squareAt(event.localPosition, size, widget.orientation);
    if (drawing == null || square == null || square == drawing.to) return;
    setState(() => _drawing = BoardShape(drawing.from, square, drawing.colour));
  }

  void _up() {
    final drawn = _drawing;
    if (drawn == null) return;
    setState(() {
      _drawing = null;
      if (widget.onDraw == null) _drawn = withShapeDrawn(_drawn, drawn);
    });
    widget.onDraw?.call(drawn);
  }

  void _cancel() {
    if (_drawing != null) setState(() => _drawing = null);
  }
}

/// The square under [at] on a board [size] wide seen from [orientation];
/// null off the board.
Square? squareAt(Offset at, double size, Side orientation) {
  final column = (at.dx * 8 / size).floor();
  final row = (at.dy * 8 / size).floor();
  if (column < 0 || column > 7 || row < 0 || row > 7) return null;
  return orientation == Side.white
      ? Square(column + (7 - row) * 8)
      : Square((7 - column) + row * 8);
}

/// The colour the keys held now draw in; Shift wins over Alt over Ctrl.
ShapeColour _heldColour() {
  final keys = HardwareKeyboard.instance;
  if (keys.isShiftPressed) return ShapeColour.red;
  if (keys.isAltPressed) return ShapeColour.blue;
  if (keys.isControlPressed) return ShapeColour.yellow;
  return ShapeColour.green;
}

Shape _shapeOf(BoardShape shape) {
  final color = switch (shape.colour) {
    ShapeColour.green => shapeGreen,
    ShapeColour.red => shapeRed,
    ShapeColour.blue => shapeBlue,
    ShapeColour.yellow => shapeYellow,
  };
  return shape.isCircle
      ? Circle(color: color, orig: shape.from)
      : Arrow(color: color, orig: shape.from, dest: shape.to);
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

/// What the board needs to show [fen] and, when [movable], let either side
/// move on it: the pieces, whose move it is, every legal move, the last move
/// and the king in check.
GameData gameOf(Fen fen, String? lastMove, {bool movable = true}) {
  final position = positionOf(fen);
  if (position == null) return _noPosition;
  return GameData(
    fen: fen.value,
    playerSide: movable ? PlayerSide.both : PlayerSide.none,
    sideToMove: position.turn,
    validMoves: makeLegalMoves(position),
    lastMove: lastMove == null ? null : Move.parse(lastMove),
    kingSquareInCheck: position.isCheck
        ? position.board.kingOf(position.turn)
        : null,
  );
}

/// A repaint-only layer under chessground's pieces and interaction highlights.
class _LegalMoveBackground extends ChessboardBackground {
  _LegalMoveBackground({
    required this.background,
    required this.controller,
    required this.selection,
    required Side side,
    required this.color,
  }) : super(
         lightSquare: background.lightSquare,
         darkSquare: background.darkSquare,
         coordinates: background.coordinates,
         orientation: side,
       );

  final ChessboardBackground background;
  final ChessboardController controller;
  final BoardHighlightNotifier selection;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('legal-move-highlights'),
    foregroundPainter: _LegalMovePainter(
      controller: controller,
      selection: selection,
      orientation: orientation,
      color: color,
    ),
    child: background,
  );
}

class _LegalMovePainter extends CustomPainter {
  _LegalMovePainter({
    required this.controller,
    required this.selection,
    required this.orientation,
    required this.color,
  }) : super(repaint: selection);

  final ChessboardController controller;
  final BoardHighlightNotifier selection;
  final Side orientation;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (!controller.interactive || controller.pendingPromotion != null) return;
    final destinations = controller.game.validMoves[selection.selected];
    if (destinations == null) return;
    final squareSize = size.width / 8;
    final paint = Paint()
      ..color = color
      ..isAntiAlias = false;
    for (final square in destinations) {
      final file = square.file;
      final rank = square.rank;
      final x = orientation == Side.white ? file : 7 - file;
      final y = orientation == Side.white ? 7 - rank : rank;
      canvas.drawRect(
        Rect.fromLTWH(x * squareSize, y * squareSize, squareSize, squareSize),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LegalMovePainter old) =>
      old.controller != controller ||
      old.selection != selection ||
      old.orientation != orientation ||
      old.color != color;
}
