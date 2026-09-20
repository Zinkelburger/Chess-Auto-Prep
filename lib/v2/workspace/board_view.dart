import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../chess/pgn/tree_edit.dart';
import '../ui/theme.dart';
import 'piece_image.dart';
import 'promotion_picker.dart';

/// A board showing one position, and the way a move is played on it.
///
/// Click a piece then its destination, or drag it there. Only legal moves
/// leave the board: an illegal destination just changes what is selected,
/// with no message, and a pawn reaching the last rank waits for the piece it
/// becomes. The widget keeps the selection and the drag, which are nobody
/// else's business; the move itself goes to [onMove] as UCI.
class BoardView extends StatefulWidget {
  const BoardView({
    super.key,
    required this.fen,
    required this.orientation,
    required this.onMove,
    this.lastMove,
  });

  final Fen fen;

  /// The side shown at the bottom.
  final Side orientation;

  final void Function(String uci) onMove;

  /// The move just played, as UCI, for the highlight; null at the start.
  final String? lastMove;

  @override
  State<BoardView> createState() => _BoardViewState();
}

/// A piece under the pointer: where it came from and where the pointer is,
/// in board coordinates.
typedef _Drag = ({Square from, Offset at});

class _BoardViewState extends State<BoardView> {
  Square? _selected;
  _Drag? _drag;
  NormalMove? _promoting;

  /// The pieces of [BoardView.fen], read when the position changes rather
  /// than on every build: a drag rebuilds the board on every pointer sample
  /// and the position does not move under it.
  List<(Square, Piece)> _pieces = const [];

  @override
  void initState() {
    super.initState();
    _pieces = _piecesOf(widget.fen);
  }

  @override
  void didUpdateWidget(BoardView old) {
    super.didUpdateWidget(old);
    // Another position: nothing selected on it, and a promotion nobody
    // answered is off.
    if (old.fen != widget.fen) {
      _pieces = _piecesOf(widget.fen);
      _selected = null;
      _drag = null;
      _promoting = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final square = constraints.maxWidth / 8;
          return GestureDetector(
            // The piece picked up is the one the pointer went down on, not
            // whichever square it had reached when the drag was recognised.
            dragStartBehavior: DragStartBehavior.down,
            onTapUp: (details) =>
                _tapped(_squareAt(details.localPosition, square)),
            onPanStart: (details) => _pickUp(details.localPosition, square),
            onPanUpdate: (details) => _moveTo(details.localPosition),
            onPanEnd: (_) => _drop(square),
            onPanCancel: _letGo,
            child: Stack(children: _layers(context, square)),
          );
        },
      ),
    );
  }

  /// The squares, then the pieces, then whatever is being carried or asked,
  /// which is the order they sit in front of each other.
  List<Widget> _layers(BuildContext context, double square) {
    return [
      Positioned.fill(child: CustomPaint(painter: _painter(context))),
      for (final (at, piece) in _pieces)
        if (at != _drag?.from)
          Positioned(
            left: _column(at, widget.orientation) * square,
            top: _row(at, widget.orientation) * square,
            width: square,
            height: square,
            child: PieceImage(piece: piece),
          ),
      if (_dragged case final piece?) _inHand(piece, square),
      if (_promoting case final move?) _picker(move, square),
    ];
  }

  Widget _inHand(Piece piece, double square) => Positioned(
    left: _drag!.at.dx - square / 2,
    top: _drag!.at.dy - square / 2,
    width: square,
    height: square,
    child: IgnorePointer(child: PieceImage(piece: piece)),
  );

  Widget _picker(NormalMove move, double square) {
    final promoting = widget.fen.whiteToMove ? Side.white : Side.black;
    return PromotionPicker(
      color: promoting,
      file: _column(move.to, widget.orientation),
      fromTop: promoting == widget.orientation,
      square: square,
      onChosen: (role) => _play(move.withPromotion(role)),
      onCancel: () => setState(() => _promoting = null),
    );
  }

  _SquaresPainter _painter(BuildContext context) => _SquaresPainter(
    colors: BoardTheme.of(context),
    orientation: widget.orientation,
    lastMove: _squaresOf(widget.lastMove),
    selected: _selected ?? _drag?.from,
  );

  Piece? get _dragged {
    final from = _drag?.from;
    if (from == null) return null;
    for (final (at, piece) in _pieces) {
      if (at == from) return piece;
    }
    return null;
  }

  void _tapped(Square? square) {
    if (_promoting != null || square == null) return;
    final from = _selected;
    if (from != null && from != square && _offer(from, square)) return;
    setState(() => _selected = _mine(square) ? square : null);
  }

  void _pickUp(Offset at, double square) {
    if (_promoting != null) return;
    final from = _squareAt(at, square);
    if (from == null || !_mine(from)) return;
    setState(() {
      _selected = null;
      _drag = (from: from, at: at);
    });
  }

  void _moveTo(Offset at) {
    final drag = _drag;
    if (drag == null) return;
    setState(() => _drag = (from: drag.from, at: at));
  }

  void _drop(double square) {
    final drag = _drag;
    if (drag == null) return;
    setState(() => _drag = null);
    final to = _squareAt(drag.at, square);
    // Let go away from the board: the piece goes back and no move is played,
    // the way a piece dropped off the table is not a move.
    if (to == null) return;
    if (to != drag.from && _offer(drag.from, to)) return;
    setState(() => _selected = drag.from);
  }

  /// The drag was taken away from us, by a second pointer or by the board
  /// going away. The piece goes back where it came from.
  void _letGo() {
    if (_drag == null) return;
    setState(() => _drag = null);
  }

  /// Plays `from`–`to` if it is legal, or asks which piece a promoting pawn
  /// becomes. False when the move is not one this position allows.
  bool _offer(Square from, Square to) {
    final position = positionOf(widget.fen);
    if (position == null) return false;
    final move = NormalMove(from: from, to: to);
    if (_promotes(position, move)) {
      setState(() {
        _selected = null;
        _promoting = move;
      });
      return true;
    }
    if (!position.isLegal(move)) return false;
    _play(move);
    return true;
  }

  void _play(NormalMove move) {
    setState(() {
      _selected = null;
      _promoting = null;
    });
    widget.onMove(move.uci);
  }

  bool _promotes(Position position, NormalMove move) =>
      position.board.roleAt(move.from) == Role.pawn &&
      SquareSet.backranks.has(move.to) &&
      position.isLegal(move.withPromotion(Role.queen));

  bool _mine(Square square) {
    final position = positionOf(widget.fen);
    return position != null && position.board.sideAt(square) == position.turn;
  }

  /// The square [at] falls on, or null when the pointer is off the board.
  Square? _squareAt(Offset at, double square) {
    final column = (at.dx / square).floor();
    final row = (at.dy / square).floor();
    if (column < 0 || column > 7 || row < 0 || row > 7) return null;
    final white = widget.orientation == Side.white;
    return Square.fromCoords(
      File(white ? column : 7 - column),
      Rank(white ? 7 - row : row),
    );
  }
}

/// Screen column and row of a square for either orientation: White sees a1
/// bottom-left, Black sees h8 bottom-left.
int _column(Square square, Side orientation) =>
    orientation == Side.white ? square.file.value : 7 - square.file.value;

int _row(Square square, Side orientation) =>
    orientation == Side.white ? 7 - square.rank.value : square.rank.value;

/// The pieces of [fen], or none when the text is not a position.
///
/// A board it cannot read is drawn empty. Letting the exception out of
/// `initState` would take the whole frame down and with it every pointer
/// this app has, which looks to the user like a dead mouse rather than one
/// bad position.
List<(Square, Piece)> _piecesOf(Fen fen) {
  try {
    return Setup.parseFen(fen.value).board.pieces.toList(growable: false);
  } on FenException {
    return const [];
  }
}

Set<Square> _squaresOf(String? uci) {
  if (uci == null) return const {};
  return switch (Move.parse(uci)) {
    NormalMove(:final from, :final to) => {from, to},
    DropMove(:final to) => {to},
    null => const {},
  };
}

class _SquaresPainter extends CustomPainter {
  _SquaresPainter({
    required this.colors,
    required this.orientation,
    required this.lastMove,
    required this.selected,
  });

  final BoardTheme colors;
  final Side orientation;
  final Set<Square> lastMove;

  /// The square the user has picked a piece up from.
  final Square? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.width / 8;
    final light = Paint()..color = colors.lightSquare;
    final dark = Paint()..color = colors.darkSquare;
    for (final square in Square.values) {
      final rect = Rect.fromLTWH(
        _column(square, orientation) * side,
        _row(square, orientation) * side,
        side,
        side,
      );
      // a1 is dark, so a square is light when file + rank is odd.
      final isLight = (square.file.value + square.rank.value).isOdd;
      canvas.drawRect(rect, isLight ? light : dark);
      final tint = _tintOf(square);
      if (tint != null) canvas.drawRect(rect, Paint()..color = tint);
    }
    _paintCoordinates(canvas, side);
  }

  /// One tint per square, never two: what the user is holding wins over
  /// where the last move went.
  Color? _tintOf(Square square) {
    if (square == selected) return colors.selected;
    if (lastMove.contains(square)) return colors.lastMove;
    return null;
  }

  /// File letters along the bottom edge and rank digits up the left edge, in
  /// the square's corner the way Lichess draws them.
  void _paintCoordinates(Canvas canvas, double side) {
    final style = colors.coordinateStyle(side);
    for (var i = 0; i < 8; i++) {
      final file = orientation == Side.white ? i : 7 - i;
      final rank = orientation == Side.white ? 7 - i : i;
      _paintText(
        canvas,
        File(file).name,
        style,
        Offset(i * side + side - side * 0.22, 8 * side - side * 0.26),
      );
      _paintText(
        canvas,
        Rank(rank).name,
        style,
        Offset(side * 0.06, i * side + side * 0.04),
      );
    }
  }

  void _paintText(Canvas canvas, String text, TextStyle style, Offset at) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_SquaresPainter old) =>
      old.orientation != orientation ||
      old.lastMove != lastMove ||
      old.selected != selected ||
      old.colors != colors;
}
