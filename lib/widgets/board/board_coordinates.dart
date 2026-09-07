/// File letters and rank numbers on a board, in the three placements lila
/// offers (inside the edge squares, in a margin outside, or on every square).
///
/// [coordinateLabels] is the whole decision — which text goes where, in what
/// colour — as data, so it is testable without a canvas. [BoardCoordinatesPainter]
/// only draws that list. The board widget owns the geometry (square size and
/// margin) and hands both in.
library;

import 'package:flutter/material.dart';

import '../../models/board_display_settings.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// Squares narrower than this are a thumbnail, and a thumbnail carries no
/// coordinates whatever the preference says (lila's mini boards are bare too).
const double kMinCoordinateSquare = 24;

/// One piece of text on or beside the board.
class CoordinateLabel {
  const CoordinateLabel({
    required this.text,
    required this.cell,
    required this.alignment,
    required this.color,
    required this.fontSize,
  });

  /// `a`–`h`, `1`–`8`, or a square name.
  final String text;

  /// The square, or margin cell, the label sits in — in the coordinate space
  /// whose origin is the top-left of the a8/h1 squares, so a margin cell has
  /// a negative left or a top past the eighth row.
  final Rect cell;

  /// Where inside [cell] the text goes.
  final Alignment alignment;
  final Color color;
  final double fontSize;

  @override
  bool operator ==(Object other) =>
      other is CoordinateLabel &&
      other.text == text &&
      other.cell == cell &&
      other.alignment == alignment &&
      other.color == color &&
      other.fontSize == fontSize;

  @override
  int get hashCode => Object.hash(text, cell, alignment, color, fontSize);

  @override
  String toString() => 'CoordinateLabel($text @ $cell $alignment)';
}

/// The margin [BoardCoordinates.outside] needs around a board [boardSize]
/// wide. Zero for every other mode, and for a board too small to label.
double coordinateMargin(BoardCoordinates mode, double boardSize) {
  if (mode != BoardCoordinates.outside) return 0;
  if (boardSize / 8 < kMinCoordinateSquare) return 0;
  return (boardSize * 0.045).clamp(14.0, 22.0);
}

/// Every label for [mode] on a board of [squareSize] squares, seen from
/// White's side unless [flipped]. [margin] is only read for
/// [BoardCoordinates.outside].
///
/// Inside the board the ink alternates with the square, as chessground does:
/// the dark-square colour on a light square and the light on a dark one, so a
/// letter never sits on its own colour. Outside, the labels are chrome and
/// take the app's muted ink.
List<CoordinateLabel> coordinateLabels({
  required BoardCoordinates mode,
  required bool flipped,
  required double squareSize,
  double margin = 0,
}) {
  if (mode == BoardCoordinates.none || squareSize < kMinCoordinateSquare) {
    return const [];
  }

  String fileAt(int col) => String.fromCharCode(97 + (flipped ? 7 - col : col));
  String rankAt(int row) => '${flipped ? row + 1 : 8 - row}';
  Rect square(int col, int row) =>
      Rect.fromLTWH(col * squareSize, row * squareSize, squareSize, squareSize);
  Color inkOn(int col, int row) {
    final file = flipped ? 7 - col : col;
    final rank = flipped ? row : 7 - row;
    final isLight = (file + rank) % 2 != 0;
    return isLight ? AppColors.boardDarkSquare : AppColors.boardLightSquare;
  }

  final labels = <CoordinateLabel>[];
  switch (mode) {
    case BoardCoordinates.none:
      break;
    case BoardCoordinates.inside:
      final size = (squareSize * 0.22).clamp(9.0, 14.0);
      for (var col = 0; col < 8; col++) {
        labels.add(
          CoordinateLabel(
            text: fileAt(col),
            cell: square(col, 7),
            alignment: Alignment.bottomRight,
            color: inkOn(col, 7),
            fontSize: size,
          ),
        );
      }
      for (var row = 0; row < 8; row++) {
        labels.add(
          CoordinateLabel(
            text: rankAt(row),
            cell: square(7, row),
            alignment: Alignment.topRight,
            color: inkOn(7, row),
            fontSize: size,
          ),
        );
      }
    case BoardCoordinates.everySquare:
      final size = (squareSize * 0.2).clamp(9.0, 13.0);
      for (var row = 0; row < 8; row++) {
        for (var col = 0; col < 8; col++) {
          labels.add(
            CoordinateLabel(
              text: '${fileAt(col)}${rankAt(row)}',
              cell: square(col, row),
              alignment: Alignment.bottomRight,
              color: inkOn(col, row),
              fontSize: size,
            ),
          );
        }
      }
    case BoardCoordinates.outside:
      final size = (margin * 0.7).clamp(9.0, 13.0);
      for (var col = 0; col < 8; col++) {
        labels.add(
          CoordinateLabel(
            text: fileAt(col),
            cell: Rect.fromLTWH(
              col * squareSize,
              8 * squareSize,
              squareSize,
              margin,
            ),
            alignment: Alignment.center,
            color: AppColors.onSurfaceMuted,
            fontSize: size,
          ),
        );
      }
      for (var row = 0; row < 8; row++) {
        labels.add(
          CoordinateLabel(
            text: rankAt(row),
            cell: Rect.fromLTWH(-margin, row * squareSize, margin, squareSize),
            alignment: Alignment.center,
            color: AppColors.onSurfaceMuted,
            fontSize: size,
          ),
        );
      }
  }
  return labels;
}

/// Draws [coordinateLabels]. The canvas origin is shifted by [origin] first,
/// so the same painter serves the board's own canvas (origin zero) and the
/// outer canvas that holds the margin (origin at the squares' top-left).
class BoardCoordinatesPainter extends CustomPainter {
  BoardCoordinatesPainter({
    required this.mode,
    required this.flipped,
    required this.squareSize,
    this.margin = 0,
    this.origin = Offset.zero,
  });

  final BoardCoordinates mode;
  final bool flipped;
  final double squareSize;
  final double margin;
  final Offset origin;

  /// Inset from the square edge for the corner placements.
  static const double _pad = 0.06;

  @override
  void paint(Canvas canvas, Size size) {
    final labels = coordinateLabels(
      mode: mode,
      flipped: flipped,
      squareSize: squareSize,
      margin: margin,
    );
    if (labels.isEmpty) return;
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    final pad = squareSize * _pad;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(
          text: label.text,
          style: TextStyle(
            fontSize: label.fontSize,
            fontWeight: FontWeight.w600,
            fontFamily: AppTextStyles.uiFamily,
            color: label.color,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      // Corner placements keep a little air off the edge; centred ones sit
      // where the alignment puts them.
      final inset = label.alignment == Alignment.center
          ? Rect.zero
          : Rect.fromLTRB(pad, pad * 0.5, pad, pad * 0.5);
      final area = Rect.fromLTRB(
        label.cell.left + inset.left,
        label.cell.top + inset.top,
        label.cell.right - inset.right,
        label.cell.bottom - inset.bottom,
      );
      final topLeft = label.alignment.inscribe(painter.size, area).topLeft;
      painter.paint(canvas, topLeft);
      painter.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BoardCoordinatesPainter old) =>
      mode != old.mode ||
      flipped != old.flipped ||
      squareSize != old.squareSize ||
      margin != old.margin ||
      origin != old.origin;
}
