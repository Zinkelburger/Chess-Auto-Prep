import 'package:flutter/material.dart';

import '../../ui/theme.dart';

/// What a drag out of the outline carries: which games of the open chapter
/// are on the move. Dropped on a chapter they become lines of their own
/// there; dropped on a line they fold into it as variations.
final class LineDrag {
  const LineDrag(this.games, {required this.label});

  final Set<int> games;

  /// What the chip under the pointer says: the line's moves, or `3 lines`.
  final String label;
}

/// The chip that follows the pointer while lines are dragged.
class LineDragChip extends StatelessWidget {
  const LineDragChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.m,
          vertical: Space.xs,
        ),
        child: Text(
          label,
          style: monoText.copyWith(color: scheme.onSurface),
          maxLines: 1,
        ),
      ),
    );
  }
}

/// A row that takes dragged lines: tinted while they hover over it, and
/// [onDrop] when they land. [accepts] says whether this row can take them
/// at all — a line cannot be dropped on itself, nor a chapter's lines on
/// the chapter they are already in.
class LineDropTarget extends StatelessWidget {
  const LineDropTarget({
    super.key,
    required this.accepts,
    required this.onDrop,
    required this.child,
  });

  final bool Function(LineDrag drag) accepts;
  final ValueChanged<LineDrag> onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<LineDrag>(
      onWillAcceptWithDetails: (details) => accepts(details.data),
      onAcceptWithDetails: (details) => onDrop(details.data),
      builder: (context, candidates, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: candidates.isEmpty
              ? Colors.transparent
              : scheme.primary.withValues(alpha: 0.15),
        ),
        child: child,
      ),
    );
  }
}
