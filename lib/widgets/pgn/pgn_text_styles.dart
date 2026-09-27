/// Movetext type scale for PGN viewer / editor surfaces.
///
/// Colors follow the active theme; notation metrics stay shared by every reader.
library;

import 'package:flutter/material.dart';

import '../../utils/pgn_nags.dart';
import '../../design_system/theme/app_typography.dart';

abstract final class PgnTextStyles {
  /// Chess notation and prose deliberately use different faces. SAN and move
  /// numbers use the bundled Source Code Pro: its unambiguous `O`/`0`, compact
  /// punctuation and even rhythm make dense variations easy to scan. Comments
  /// inherit Inter from the app theme, so a course chapter still reads like a
  /// book instead of a code listing.

  /// Indent applied per nesting level by the movetext view.
  static const depthIndent = 18.0;

  /// Cap structural indentation so deep branches retain a readable measure.
  static const maxStyledDepth = 3;

  /// Mainline and variations share legible ink; indentation carries depth.
  static Color inkAt(BuildContext context, int depth) =>
      Theme.of(context).colorScheme.onSurface;

  static double sizeAt(int depth) => 16;

  /// SAN uses a consistent size and regular weight, including annotated
  /// moves and sidelines. Depth is carried by ink, indentation and folds.
  ///
  /// Note the current move does **not** get extra weight: the pill marks it.
  /// A weight change on navigation would still alter glyph widths and reflow
  /// the wrapped pane, even in the notation face.
  static TextStyle moveAt(
    BuildContext context,
    int depth, {
    bool ephemeral = false,
  }) => TextStyle(
    fontFamily: AppTypography.monoFamily,
    fontSize: sizeAt(depth),
    height: 1.7,
    fontWeight: FontWeight.w400,
    // Ephemeral (scratch / solitaire) moves italicize rather than take a hue:
    // "unsaved" is orthogonal to depth, so it gets an orthogonal axis.
    fontStyle: ephemeral ? FontStyle.italic : FontStyle.normal,
    color: inkAt(context, depth),
  );

  /// Complete NAG suffix, with the viewer's quality color and stable size.
  static TextStyle nagAt(
    BuildContext context,
    int depth, {
    required TextStyle moveStyle,
    List<int>? nags,
  }) => moveStyle.copyWith(
    color: nagInk(context, primaryQualityNag(nags) ?? 0),
    fontSize: sizeAt(depth) - 1,
    fontWeight: FontWeight.bold,
  );

  /// Keep the annotation's hue while making its ink legible on the actual
  /// glyph fill, or on ordinary, hovered and selected movetext backgrounds.
  static Color annotationInk(
    BuildContext context,
    Color semanticColor, {
    Color? background,
  }) {
    final colors = Theme.of(context).colorScheme;
    final surfaces = background == null
        ? [
            colors.surfaceContainerLow,
            colors.surfaceContainerHighest,
            colors.primaryContainer,
          ]
        : [background];
    final hsl = HSLColor.fromColor(semanticColor);
    final target = colors.brightness == Brightness.light ? 0.0 : 1.0;
    for (var step = 0; step <= 24; step++) {
      final candidate = hsl
          .withLightness(hsl.lightness + (target - hsl.lightness) * step / 24)
          .toColor();
      if (surfaces.every((surface) => _contrast(candidate, surface) >= 4.5)) {
        return candidate;
      }
    }
    return colors.onSurface;
  }

  static Color nagInk(BuildContext context, int id) =>
      annotationInk(context, nagColor(id));

  static double _contrast(Color foreground, Color background) {
    final a = foreground.computeLuminance() + .05;
    final b = background.computeLuminance() + .05;
    return a > b ? a / b : b / a;
  }

  /// `1.` / `2...` at [depth] — always regular weight, always a step below its
  /// move's ink.
  static TextStyle moveNumberAt(BuildContext context, int depth) => TextStyle(
    fontFamily: AppTypography.monoFamily,
    fontSize: sizeAt(depth),
    height: 1.7,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );

  /// Parentheses are only used for short inline alternatives. Block
  /// variations already have a gutter and indent, so brackets there would be
  /// redundant visual noise.
  static TextStyle parenthesisAt(BuildContext context, int depth) => TextStyle(
    fontFamily: AppTypography.monoFamily,
    fontSize: sizeAt(depth),
    height: 1.7,
    fontWeight: FontWeight.w600,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );

  /// Comment prose at [depth]. Upright — book chapters are mostly comments,
  /// and italicizing the whole pane makes the moves harder to scan. Depth
  /// is carried by the gutter, never by making explanations smaller.
  static TextStyle commentAt(BuildContext context, int depth) => TextStyle(
    fontFamily: AppTypography.uiFamily,
    fontSize: 17,
    height: 1.72,
    color: Theme.of(context).colorScheme.onSurface,
  );

  /// Generated `[%...]` metrics at [depth]. Upright, because they are measured
  /// data rather than commentary, and a step quieter than the moves they
  /// describe so a line of them never competes with the movetext.
  static TextStyle metricsAt(BuildContext context, int depth) => TextStyle(
    fontFamily: AppTypography.uiFamily,
    fontSize: depth == 0 ? 12.5 : 12,
    height: 1.5,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );

  /// Root style for a movetext row's RichText at [depth]. Individual notation
  /// and prose spans set their own family; keeping the root neutral prevents a
  /// comment from accidentally inheriting the mono face.
  static TextStyle rowRootAt(BuildContext context, int depth) => TextStyle(
    fontSize: sizeAt(depth),
    height: 1.4,
    color: inkAt(context, depth),
  );

  /// A variation disclosure is labelled by its first numbered move.
  static TextStyle collapsedStub(BuildContext context) => TextStyle(
    fontFamily: AppTypography.monoFamily,
    fontSize: 14,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );

  // ── Depth-0 aliases (kept for the comment renderers) ─────────────────────

  static TextStyle move(BuildContext context) => moveAt(context, 0);
  static TextStyle comment(BuildContext context) => commentAt(context, 0);

  /// Text on the "you are here" pill. Same metrics as [move] so the pill can
  /// move without reflowing anything around it.
  static TextStyle currentMove(BuildContext context) => moveAt(
    context,
    0,
  ).copyWith(color: Theme.of(context).colorScheme.onPrimaryContainer);

  /// Branch-picker chips under the movetext mirror the notation face.
  static TextStyle branchChip(BuildContext context) => TextStyle(
    fontFamily: AppTypography.monoFamily,
    fontSize: 15,
    height: 1.2,
    color: Theme.of(context).colorScheme.onSurface,
  );

  static TextStyle branchChipBadge(BuildContext context) => TextStyle(
    fontFamily: AppTypography.uiFamily,
    fontSize: 12,
    height: 1.1,
    fontWeight: FontWeight.w600,
    color: Theme.of(context).colorScheme.onSurface,
  );

  // ── Rich comment blocks (Chessable/Forward Chess book formatting) ───────

  static TextStyle commentHeader(BuildContext context) => TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.bold,
    height: 1.4,
    color: Theme.of(context).colorScheme.onSurface,
  );

  static TextStyle commentQuote(BuildContext context) => TextStyle(
    fontSize: 17,
    height: 1.72,
    color: Theme.of(context).colorScheme.onSurface,
  );

  static TextStyle commentBracket(BuildContext context) => TextStyle(
    fontSize: 17,
    height: 1.72,
    color: Theme.of(context).colorScheme.onSurface,
  );

  static TextStyle commentFen(BuildContext context) => TextStyle(
    fontFamily: AppTypography.monoFamily,
    fontSize: 12,
    color: Theme.of(context).colorScheme.onSurface,
  );

  static TextStyle commentLink(BuildContext context) => TextStyle(
    fontFamily: AppTypography.monoFamily,
    fontSize: 14,
    height: 1.5,
    color: Theme.of(context).colorScheme.tertiary,
    decoration: TextDecoration.underline,
    decorationColor: Theme.of(context).colorScheme.tertiary,
  );
}
