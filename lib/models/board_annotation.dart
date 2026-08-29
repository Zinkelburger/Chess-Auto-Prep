/// Board arrows, circles, and labels drawn on [ChessBoardWidget].
///
/// Lives in `models/` so services and utils can build annotations without
/// importing widgets.
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Predefined annotation brushes (color + opacity + stroke width).
enum AnnotationBrush {
  green(AppColors.boardArrowGreen, 3.0),
  red(AppColors.boardArrowRed, 3.0),
  blue(AppColors.boardArrowBlue, 3.0),
  yellow(AppColors.boardArrowYellow, 3.0),
  purple(AppColors.boardArrowPurple, 3.0);

  final Color color;
  final double strokeWidthFactor;
  const AnnotationBrush(this.color, this.strokeWidthFactor);
}

/// A single annotation drawn on the board.
///
/// - Arrow: both [orig] and [dest] set, different squares.
/// - Circle: only [orig] set (or [dest] == [orig]).
/// - Either may carry an optional [label] rendered at the target square.
class BoardAnnotation {
  final String orig;
  final String? dest;
  final AnnotationBrush brush;
  final String? label;

  const BoardAnnotation({
    required this.orig,
    this.dest,
    this.brush = AnnotationBrush.green,
    this.label,
  });

  bool get isArrow => dest != null && dest != orig;
  bool get isCircle => !isArrow;

  /// Arrow for a standard UCI move (`e2e4`, `e7e8q`), or null when [uci] is
  /// not four valid square characters. Used to echo a hovered move onto the
  /// board.
  static BoardAnnotation? arrowFromUci(
    String uci, {
    AnnotationBrush brush = AnnotationBrush.blue,
  }) {
    if (!_uciSquares.hasMatch(uci)) return null;
    final orig = uci.substring(0, 2);
    final dest = uci.substring(2, 4);
    if (orig == dest) return null;
    return BoardAnnotation(orig: orig, dest: dest, brush: brush);
  }

  static final _uciSquares = RegExp(r'^[a-h][1-8][a-h][1-8]');

  @override
  bool operator ==(Object other) =>
      other is BoardAnnotation &&
      other.orig == orig &&
      other.dest == dest &&
      other.brush == brush &&
      other.label == label;

  @override
  int get hashCode => Object.hash(orig, dest, brush, label);
}
