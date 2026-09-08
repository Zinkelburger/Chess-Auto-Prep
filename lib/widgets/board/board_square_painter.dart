/// Shared board surface and square feedback for interactive boards and previews.
library;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Board squares are painted once, with any tint composited into their colour.
/// Selection wins over explicit highlights, which win over recent-move tints.
/// Legal destinations are independent dots (empty) or inset rings (occupied).
/// No highlight changes layout, draws a square border, or blends with siblings.
class BoardSquarePainter extends CustomPainter {
  BoardSquarePainter({
    this.flipped = false,
    this.selectedSquare,
    Set<String> highlightedSquares = const {},
    Set<String> recentMoveSquares = const {},
    Set<String> legalMoveSquares = const {},
    Set<String> occupiedSquares = const {},
    this.outlineWidth = 2,
  }) : highlightedSquares = Set.unmodifiable(highlightedSquares),
       recentMoveSquares = Set.unmodifiable(recentMoveSquares),
       legalMoveSquares = Set.unmodifiable(legalMoveSquares),
       occupiedSquares = Set.unmodifiable(occupiedSquares);

  final bool flipped;
  final String? selectedSquare;
  final Set<String> highlightedSquares;
  final Set<String> recentMoveSquares;
  final Set<String> legalMoveSquares;
  final Set<String> occupiedSquares;

  /// The board's permanent outer frame, independent of square feedback.
  final double outlineWidth;

  static (int, int) squareToCoords(String square, bool flipped) {
    final file = square.codeUnitAt(0) - 97;
    final rank = int.parse(square[1]) - 1;
    return (flipped ? 7 - file : file, flipped ? rank : 7 - rank);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.width / 8;
    // Adjacent rectangles must own the same raster boundary at fractional
    // sizes. Antialiasing individual tiles produces hairline seams.
    final tilePaint = Paint()..isAntiAlias = false;
    final markerPaint = Paint()..color = AppColors.boardLegalMove;
    for (var file = 0; file < 8; file++) {
      for (var rank = 0; rank < 8; rank++) {
        final square = '${String.fromCharCode(97 + file)}${rank + 1}';
        final col = flipped ? 7 - file : file;
        final row = flipped ? rank : 7 - rank;
        final rect = Rect.fromLTRB(
          col * side,
          row * side,
          (col + 1) * side,
          (row + 1) * side,
        );
        final base = (file + rank).isOdd
            ? AppColors.boardLightSquare
            : AppColors.boardDarkSquare;
        final Color? tint;
        if (square == selectedSquare) {
          tint = AppColors.boardSelected;
        } else if (highlightedSquares.contains(square)) {
          tint = AppColors.boardHighlight;
        } else if (recentMoveSquares.contains(square)) {
          tint = AppColors.boardRecentMove;
        } else {
          tint = null;
        }
        tilePaint.color = tint == null ? base : Color.alphaBlend(tint, base);
        canvas.drawRect(rect, tilePaint);

        if (square != selectedSquare && legalMoveSquares.contains(square)) {
          final occupied = occupiedSquares.contains(square);
          markerPaint
            ..style = occupied ? PaintingStyle.stroke : PaintingStyle.fill
            ..strokeWidth = side * 0.065;
          canvas.drawCircle(
            rect.center,
            side * (occupied ? 0.43 : 0.14),
            markerPaint,
          );
        }
      }
    }
    if (outlineWidth > 0) {
      canvas.drawRect(
        (Offset.zero & size).deflate(outlineWidth / 2),
        Paint()
          ..color = AppColors.boardOutline
          ..style = PaintingStyle.stroke
          ..strokeWidth = outlineWidth,
      );
    }
  }

  @override
  bool shouldRepaint(covariant BoardSquarePainter old) =>
      flipped != old.flipped ||
      selectedSquare != old.selectedSquare ||
      outlineWidth != old.outlineWidth ||
      !setEquals(highlightedSquares, old.highlightedSquares) ||
      !setEquals(recentMoveSquares, old.recentMoveSquares) ||
      !setEquals(legalMoveSquares, old.legalMoveSquares) ||
      !setEquals(occupiedSquares, old.occupiedSquares);
}
