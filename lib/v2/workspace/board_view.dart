import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../chess/fen.dart';
import '../ui/theme.dart';

/// A board showing one position: squares, coordinates, the last move and the
/// pieces. Pure view; it draws its inputs and takes no input yet.
class BoardView extends StatelessWidget {
  const BoardView({
    super.key,
    required this.fen,
    required this.orientation,
    this.lastMove,
  });

  final Fen fen;

  /// The side shown at the bottom.
  final Side orientation;

  /// The move just played, as UCI, for the highlight; null at the start.
  final String? lastMove;

  @override
  Widget build(BuildContext context) {
    final colors = BoardTheme.of(context);
    final pieces = _pieces(fen);
    final highlighted = _squaresOf(lastMove);
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final square = constraints.maxWidth / 8;
          return Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _SquaresPainter(
                    colors: colors,
                    orientation: orientation,
                    highlighted: highlighted,
                  ),
                ),
              ),
              for (final (at, piece) in pieces)
                Positioned(
                  left: _column(at, orientation) * square,
                  top: _row(at, orientation) * square,
                  width: square,
                  height: square,
                  child: _PieceImage(piece: piece),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Screen column and row of a square for either orientation: White sees a1
/// bottom-left, Black sees h8 bottom-left.
int _column(Square square, Side orientation) =>
    orientation == Side.white ? square.file.value : 7 - square.file.value;

int _row(Square square, Side orientation) =>
    orientation == Side.white ? 7 - square.rank.value : square.rank.value;

Iterable<(Square, Piece)> _pieces(Fen fen) =>
    Setup.parseFen(fen.value).board.pieces;

Set<Square> _squaresOf(String? uci) {
  if (uci == null) return const {};
  return switch (Move.parse(uci)) {
    NormalMove(:final from, :final to) => {from, to},
    DropMove(:final to) => {to},
    null => const {},
  };
}

class _PieceImage extends StatelessWidget {
  const _PieceImage({required this.piece});

  final Piece piece;

  @override
  Widget build(BuildContext context) {
    final color = piece.color == Side.white ? 'w' : 'b';
    return SvgPicture.asset(
      'assets/pieces/$color${piece.role.uppercaseLetter}.svg',
      fit: BoxFit.contain,
    );
  }
}

class _SquaresPainter extends CustomPainter {
  _SquaresPainter({
    required this.colors,
    required this.orientation,
    required this.highlighted,
  });

  final BoardTheme colors;
  final Side orientation;
  final Set<Square> highlighted;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.width / 8;
    final light = Paint()..color = colors.lightSquare;
    final dark = Paint()..color = colors.darkSquare;
    final highlight = Paint()..color = colors.lastMove;
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
      if (highlighted.contains(square)) canvas.drawRect(rect, highlight);
    }
    _paintCoordinates(canvas, side);
  }

  /// File letters along the bottom edge and rank digits up the left edge, in
  /// the square's corner the way Lichess draws them.
  void _paintCoordinates(Canvas canvas, double side) {
    final style = TextStyle(color: colors.coordinate, fontSize: side * 0.18);
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
      old.highlighted != highlighted ||
      old.colors != colors;
}
