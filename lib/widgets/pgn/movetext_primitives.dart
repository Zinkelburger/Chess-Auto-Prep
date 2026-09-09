/// Shared movetext render primitives.
///
/// The tree editor and PGN viewer share move-chip assembly, borderless
/// selection/hover decoration, and annotation glyph controls. Hosts supply
/// depth-aware text styles and callbacks without duplicating the visuals.
library;

import '../../utils/pgn_nags.dart';
import 'package:flutter/material.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/app_colors.dart';
import '../../utils/san_display.dart';

/// Borderless move states shared by the editor, mainline and sidelines.
/// A transparent border keeps the existing one-pixel inset in every state;
/// selecting or hovering a move must never resize or reflow its paragraph.
abstract final class PgnMoveDecorations {
  static const idle = BoxDecoration(
    borderRadius: BorderRadius.all(Radius.circular(3)),
    border: Border.fromBorderSide(BorderSide(color: Colors.transparent)),
  );

  static final hover = idle.copyWith(color: AppColors.pgnMoveHoverBg);
  static final current = idle.copyWith(color: AppColors.pgnMoveCurrentBg);
  static final ephemeral = idle.copyWith(color: AppColors.pgnEphemeralBg);
  static final contextPath = idle.copyWith(
    color: AppColors.pgnMoveCurrentBg.withValues(alpha: 0.35),
  );

  static BoxDecoration resolve({
    bool selected = false,
    bool hovered = false,
    bool isEphemeral = false,
    bool onContextPath = false,
  }) {
    if (selected) return isEphemeral ? ephemeral : current;
    if (hovered) return hover;
    return onContextPath ? contextPath : idle;
  }
}

/// A tappable SAN chip with the complete NAG suffix (`Nf3!⩲`).
/// Hosts use [PgnMoveDecorations] for matching selection and hover geometry.
class MoveChip extends StatefulWidget {
  final String san;

  /// Concatenated annotation symbols, or `''` for none (see
  /// [allNagSuffix]).
  final String nagSuffix;

  final TextStyle sanStyle;
  final TextStyle nagStyle;

  /// Container decoration (background + border). Null renders no box.
  final BoxDecoration? decoration;

  /// Decoration swapped in while the pointer is over the chip. Null keeps
  /// [decoration] and leaves the cursor alone (no hover affordance).
  final BoxDecoration? hoverDecoration;

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
    this.hoverDecoration,
    this.padding = const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
    this.containerKey,
    this.behavior,
    this.onTap,
    this.onSecondaryTapDown,
  });

  @override
  State<MoveChip> createState() => _MoveChipState();
}

class _MoveChipState extends State<MoveChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final interactive = widget.hoverDecoration != null && widget.onTap != null;
    final chip = GestureDetector(
      behavior: widget.behavior,
      onTap: widget.onTap,
      onSecondaryTapDown: widget.onSecondaryTapDown,
      child: Container(
        key: widget.containerKey,
        padding: widget.padding,
        decoration: _hovered && interactive
            ? widget.hoverDecoration
            : widget.decoration,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: displaySan(context, widget.san),
                style: widget.sanStyle,
              ),
              if (widget.nagSuffix.isNotEmpty)
                TextSpan(text: widget.nagSuffix, style: widget.nagStyle),
            ],
          ),
        ),
      ),
    );
    if (!interactive) return chip;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!mounted) return;
        setState(() => _hovered = true);
      },
      onExit: (_) {
        if (!mounted) return;
        setState(() => _hovered = false);
      },
      child: chip,
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
                  : AppColors.outline,
            ),
          ),
          child: Text(
            symbol,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              fontFamily: AppTextStyles.monoFamily,
              color: onTap == null
                  ? AppColors.onSurfaceDisabled
                  : (isActive ? color : AppColors.ink),
            ),
          ),
        ),
      ),
    );
  }
}
