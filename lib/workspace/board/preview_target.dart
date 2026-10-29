import 'package:flutter/material.dart';

import '../../ui/move_notation.dart';
import '../../ui/theme.dart';

/// Where a move's floating board hangs: under the middle of [context]'s box.
Offset previewAnchor(BuildContext context) {
  final box = context.findRenderObject() as RenderBox;
  return box.localToGlobal(Offset(box.size.width / 2, box.size.height));
}

/// A row or a move that floats the board after it while the pointer rests
/// on it, and goes there when clicked.
class PreviewTarget extends StatelessWidget {
  const PreviewTarget({
    super.key,
    required this.onHover,
    required this.onLeave,
    required this.onTap,
    this.token = false,
    required this.child,
  });

  /// Called with where the board hangs, under this target.
  final ValueChanged<Offset> onHover;
  final VoidCallback onLeave;
  final VoidCallback onTap;

  /// A move in a line rather than a table's row: the pointer's tint is the
  /// move's own, with rounded corners.
  final bool token;
  final Widget child;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => onHover(previewAnchor(context)),
    onExit: (_) => onLeave(),
    child: InkWell(
      onTap: onTap,
      borderRadius: token ? moveTokenRadius : null,
      hoverColor: token
          ? Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: moveHoverAlpha)
          : null,
      child: child,
    ),
  );
}

/// One move of a line, as the engine and the bughouse lab write them: what
/// goes before it muted, the move in the text colour, bold when [strong].
/// Without [onTap] it is muted and does nothing.
class LineMoveToken extends StatelessWidget {
  const LineMoveToken({
    super.key,
    required this.label,
    required this.san,
    required this.height,
    this.strong = false,
    required this.onHover,
    required this.onLeave,
    this.onTap,
  });

  final String label;
  final String san;
  final double height;
  final bool strong;
  final ValueChanged<Offset> onHover;
  final VoidCallback onLeave;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      // As wide as its text, or the row's loose width would be taken.
      child: Center(
        widthFactor: 1,
        child: Text.rich(
          TextSpan(
            children: [
              if (label.isNotEmpty)
                TextSpan(
                  text: '$label ',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              TextSpan(text: displaySan(context, san)),
            ],
          ),
          style: monoText.copyWith(
            color: onTap == null ? scheme.onSurfaceVariant : scheme.onSurface,
            fontWeight: strong ? FontWeight.w600 : null,
          ),
        ),
      ),
    );
    final tap = onTap;
    return SizedBox(
      height: height,
      child: tap == null
          ? text
          : PreviewTarget(
              onHover: onHover,
              onLeave: onLeave,
              onTap: tap,
              token: true,
              child: text,
            ),
    );
  }
}
