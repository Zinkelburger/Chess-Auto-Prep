/// Movetext type scale for PGN viewer / editor surfaces.
///
/// Colors come from [AppColors]; shared scale from [AppTextStyles]. Change
/// appearance here (or the AppColors `pgn*` tokens) — not at call sites.
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_text_styles.dart';

abstract final class PgnTextStyles {
  /// Movetext is **proportional**, not monospace. The pane is a flowing wrap,
  /// not an aligned column, so equal advance widths buy no alignment while
  /// costing ~15% width and giving notation a code-listing texture. Print
  /// chess (and Lichess) set movetext proportional for the same reason.
  /// Monospace survives only where characters must line up: [commentFen].

  /// Indent applied per nesting level by the movetext view.
  static const depthIndent = 15.0;

  /// Deepest level with its own type treatment; beyond it, only the indent
  /// changes. Three visible steps is the practical ceiling for value scales.
  static const maxStyledDepth = 3;

  static const _sizes = <double>[14.5, 13.5, 13.0, 13.0];

  static const _inks = <Color>[
    AppColors.pgnMove,
    AppColors.pgnVariation,
    AppColors.pgnVariationDeep,
    AppColors.pgnVariationDeepest,
  ];

  static const _numberInks = <Color>[
    AppColors.pgnMoveNumber,
    AppColors.pgnMoveNumberDepth1,
    AppColors.pgnMoveNumberDepth2,
    AppColors.pgnMoveNumberDepth3,
  ];

  static int _clamp(int depth) => depth.clamp(0, maxStyledDepth);

  /// SAN ink at nesting [depth] (0 = mainline).
  static Color inkAt(int depth) => _inks[_clamp(depth)];

  static double sizeAt(int depth) => _sizes[_clamp(depth)];

  /// SAN style at [depth]. The mainline is semibold and every sideline is
  /// regular — the print convention (bold mainline, roman variations). Weight
  /// stays a *two-state* signal on purpose; further depth is carried by ink
  /// value, size, and indentation, which have more usable steps.
  ///
  /// Note the current move does **not** get extra weight: the pill marks it.
  /// A weight change on navigation would reflow the whole wrapped pane now
  /// that the face is proportional.
  static TextStyle moveAt(int depth, {bool ephemeral = false}) => TextStyle(
    fontSize: sizeAt(depth),
    height: 1.4,
    fontWeight: depth == 0 ? FontWeight.w600 : FontWeight.w400,
    // Ephemeral (scratch / solitaire) moves italicize rather than take a hue:
    // "unsaved" is orthogonal to depth, so it gets an orthogonal axis.
    fontStyle: ephemeral ? FontStyle.italic : FontStyle.normal,
    color: inkAt(depth),
  );

  /// `1.` / `2...` at [depth] — always regular weight, always a step below its
  /// move's ink.
  static TextStyle moveNumberAt(int depth) => TextStyle(
    fontSize: sizeAt(depth),
    height: 1.4,
    color: _numberInks[_clamp(depth)],
  );

  /// Comment prose at [depth]. Upright — book chapters are mostly comments,
  /// and italicizing the whole pane makes the moves harder to scan. Depth
  /// still recedes via ink and size.
  static TextStyle commentAt(int depth) => TextStyle(
    fontSize: depth == 0 ? 14 : 13,
    height: 1.5,
    color: depth == 0 ? AppColors.pgnComment : inkAt(depth),
  );

  /// Generated `[%...]` metrics at [depth]. Upright, because they are measured
  /// data rather than commentary, and a step quieter than the moves they
  /// describe so a line of them never competes with the movetext.
  static TextStyle metricsAt(int depth) => TextStyle(
    fontSize: depth == 0 ? 12.5 : 12,
    height: 1.5,
    color: AppColors.onSurfaceMuted,
  );

  /// Root style for a movetext row's RichText at [depth]. Font-family-free by
  /// construction (everything here is proportional), and weight-free so that
  /// prose spans inside a mainline row don't inherit the mainline's semibold.
  static TextStyle rowRootAt(int depth) =>
      TextStyle(fontSize: sizeAt(depth), height: 1.4, color: inkAt(depth));

  /// The "⋯ 3 more lines" disclosure that stands in for collapsed deep
  /// sidelines.
  static const collapsedStub = TextStyle(
    fontSize: 12.5,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: AppColors.pgnVariationDeepest,
  );

  // ── Depth-0 aliases (kept for the comment renderers) ─────────────────────

  static TextStyle get move => moveAt(0);
  static TextStyle get comment => commentAt(0);

  /// Text on the "you are here" pill. Same metrics as [move] so the pill can
  /// move without reflowing anything around it.
  static TextStyle get currentMove =>
      moveAt(0).copyWith(color: AppColors.pgnMoveCurrentFg);

  /// Branch-picker chips under the movetext. Proportional to match the
  /// movetext they mirror.
  static const branchChip = TextStyle(
    fontSize: 15,
    height: 1.2,
    color: AppTextStyles.ink,
  );

  static const branchChipBadge = TextStyle(
    fontSize: 12,
    height: 1.1,
    fontWeight: FontWeight.w600,
    color: AppTextStyles.ink,
  );

  // ── Rich comment blocks (Chessable/Forward Chess book formatting) ───────

  static const commentHeader = TextStyle(
    fontSize: 15.5,
    fontWeight: FontWeight.bold,
    height: 1.4,
    color: AppColors.pgnComment,
  );

  static const commentQuote = TextStyle(
    fontSize: 13.5,
    height: 1.5,
    color: Color(0xDDF2F2F2),
  );

  static const commentBracket = TextStyle(
    fontSize: 13.5,
    height: 1.4,
    color: AppColors.pgnComment,
  );

  static const commentFen = TextStyle(
    fontFamily: 'monospace',
    fontSize: 11.5,
    color: AppColors.pgnComment,
  );

  static const commentLink = TextStyle(
    fontFamily: 'monospace',
    fontSize: 13.5,
    height: 1.5,
    color: AppColors.info,
    decoration: TextDecoration.underline,
    decorationColor: AppColors.info,
  );
}
