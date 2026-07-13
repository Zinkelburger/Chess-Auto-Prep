/// Shared movetext render primitives.
///
/// Both movetext surfaces — the editable [InteractivePgnEditor] (over a
/// [MoveTree]) and the read/analysis [PgnMovetextView] (over a dartchess
/// [PgnGame]) — draw the same two pixels: a tappable SAN chip with an optional
/// bold move-quality-glyph suffix, and the glyph toggle buttons of the
/// annotation bar. They historically reimplemented both, which is exactly where
/// the NAG-rendering contract drifted (and a serialization bug hid). These
/// widgets are the single implementation; each surface supplies its own fully
/// resolved styles/decoration so their distinct looks (font size, selection
/// highlight, ephemeral colours) are preserved.
///
/// Pure NAG helpers ([primaryQualityNag], [qualityNagSuffix], [toggleQualityNag])
/// live in `pgn_comment_utils.dart` so the model layer can share them too.
library;

import 'package:flutter/material.dart';

/// A single move in the movetext: the SAN, an optional bold NAG-quality glyph
/// suffix (`Nf3` → `Nf3!?`), wrapped in a tappable rounded container.
///
/// The caller resolves all styling: [sanStyle] for the SAN, [nagStyle] for the
/// suffix (only used when [nagSuffix] is non-empty), and [decoration] for the
/// container (selection highlight / reserved border). This keeps one assembly
/// site for the SAN+suffix contract without flattening each surface's look.
class MoveChip extends StatelessWidget {
  final String san;

  /// Concatenated quality-glyph symbols, or `''` for none (see
  /// [qualityNagSuffix]).
  final String nagSuffix;

  final TextStyle sanStyle;
  final TextStyle nagStyle;

  /// Container decoration (background + border). Null renders no box.
  final BoxDecoration? decoration;

  final EdgeInsetsGeometry padding;

  /// Attached to the container so a host can scroll it into view (the PGN
  /// viewer's current-move key).
  final Key? containerKey;

  /// Hit-test behavior of the tap detector. The viewer uses
  /// [HitTestBehavior.opaque] so taps land even on the container's padding.
  final HitTestBehavior? behavior;

  final GestureTapCallback? onTap;
  final GestureTapDownCallback? onSecondaryTapDown;

  const MoveChip({
    super.key,
    required this.san,
    required this.nagSuffix,
    required this.sanStyle,
    required this.nagStyle,
    this.decoration,
    this.padding = const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
    this.containerKey,
    this.behavior,
    this.onTap,
    this.onSecondaryTapDown,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: behavior,
      onTap: onTap,
      onSecondaryTapDown: onSecondaryTapDown,
      child: Container(
        key: containerKey,
        padding: padding,
        decoration: decoration,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: san, style: sanStyle),
              if (nagSuffix.isNotEmpty)
                TextSpan(text: nagSuffix, style: nagStyle),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single move-quality glyph toggle (`!`, `?`, `!!`, …) used by the
/// annotation bars in both the PGN viewer and the repertoire/study editor.
/// Disabled (greyed, non-tappable) when [onTap] is null.
class GlyphButton extends StatelessWidget {
  final String symbol;
  final String name;
  final Color color;
  final bool isActive;
  final VoidCallback? onTap;

  const GlyphButton({
    super.key,
    required this.symbol,
    required this.name,
    required this.color,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: name,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: isActive ? color.withValues(alpha: 0.2) : null,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: isActive
                  ? color.withValues(alpha: 0.7)
                  : Colors.grey.withValues(alpha: 0.3),
            ),
          ),
          child: Text(
            symbol,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              color: onTap == null
                  ? Colors.grey[700]
                  : (isActive ? color : Colors.grey[400]),
            ),
          ),
        ),
      ),
    );
  }
}
