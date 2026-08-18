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
}
