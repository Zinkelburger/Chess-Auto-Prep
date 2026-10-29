import 'package:flutter/material.dart';

import '../../storage/chapter_files.dart';
import '../../ui/move_notation.dart';
import '../../ui/row_actions.dart';
import '../../ui/theme.dart';
import 'chapter_outline.dart';

/// One chapter of the outline. The one on the board is bold and accented,
/// because it is where every other panel is pointing.
///
/// A chapter that starts after some moves prints them under its name, so a
/// chapter set up for one opening says which. A draft — proposed lines
/// nobody has accepted yet — is muted and says "Proposed".
class ChapterRow extends StatelessWidget {
  const ChapterRow({
    super.key,
    required this.chapter,
    required this.onOpen,
    this.onDrop,
  });

  final OutlineChapter chapter;
  final ValueChanged<ChapterRef> onOpen;

  /// Lines dropped on this chapter become lines of it. Null for a chapter
  /// that cannot take them: the one they are being dragged out of.
  final ValueChanged<LineDrag>? onDrop;

  @override
  Widget build(BuildContext context) {
    final row = _row(context);
    final drop = onDrop;
    if (drop == null) return row;
    return LineDropTarget(accepts: (_) => true, onDrop: drop, child: row);
  }

  Widget _row(BuildContext context) {
    final theme = Theme.of(context);
    final heading = chapter.ref.heading;
    final rooted = !heading.startsAtTheStart;
    return InkWell(
      onTap: () => onOpen(chapter.ref),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: rooted
              ? outlineRowHeight + outlineRootHeight
              : outlineRowHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.m,
            vertical: Space.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _nameRow(theme),
              if (rooted)
                Tooltip(
                  message: heading.rootText,
                  child: Text(
                    heading.rootText,
                    overflow: TextOverflow.ellipsis,
                    style: outlineRootText.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nameRow(ThemeData theme) {
    final draft = chapter.ref.heading.draft;
    return Row(
      children: [
        Expanded(
          child: Tooltip(
            message: chapter.name,
            child: Text(
              chapter.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: chapter.open ? FontWeight.w600 : null,
                color: chapter.open
                    ? theme.colorScheme.primary
                    : draft
                    ? theme.colorScheme.onSurfaceVariant
                    : null,
              ),
            ),
          ),
        ),
        if (draft)
          Padding(
            padding: const EdgeInsets.only(left: Space.s),
            child: Text('Proposed', style: theme.textTheme.labelSmall),
          ),
        if (chapter.lines case final lines?)
          Padding(
            padding: const EdgeInsets.only(left: Space.s),
            child: Text(
              lines == 1 ? '1 line' : '$lines lines',
              style: theme.textTheme.labelSmall,
            ),
          ),
      ],
    );
  }
}

/// One line of the open chapter: what it is called, where it starts, and the
/// menu of what can be done to it. It can be picked up and dropped on a
/// chapter or on another line, and other lines can be dropped on it.
class LineRow extends StatelessWidget {
  const LineRow({
    super.key,
    required this.line,
    required this.current,
    required this.selected,
    required this.drag,
    required this.onTap,
    required this.onDrop,
    required this.actions,
  });

  final OutlineLine line;

  /// The cursor is on one of this line's moves.
  final bool current;

  /// Picked with Ctrl or Shift, so it moves with the others picked.
  final bool selected;

  /// What a drag starting on this row carries.
  final LineDrag drag;

  final VoidCallback onTap;

  /// Lines dropped on this one fold into it as variations.
  final ValueChanged<LineDrag> onDrop;

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return LineDropTarget(
      accepts: (dropped) => !dropped.games.contains(line.game),
      onDrop: onDrop,
      child: Draggable<LineDrag>(
        data: drag,
        feedback: LineDragChip(label: drag.label),
        childWhenDragging: Opacity(opacity: 0.4, child: _row(context)),
        child: _row(context),
      ),
    );
  }

  Widget _row(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.2)
          : current
          ? theme.colorScheme.surfaceContainerHighest
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: outlineRowHeight),
          child: Padding(
            padding: const EdgeInsets.only(left: Space.m + outlineIndent),
            child: Row(
              children: [
                if (!line.shared) ...[
                  Flexible(
                    child: Tooltip(
                      message: line.name,
                      child: Text(line.name, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  const SizedBox(width: Space.s),
                ],
                Expanded(
                  child: Tooltip(
                    message: displaySan(context, line.moves),
                    child: Text(
                      displaySan(context, line.moves),
                      overflow: TextOverflow.ellipsis,
                      style: monoText.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                RowActions(children: actions),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A sentence where rows would be: nothing here yet, or nothing matching.
class OutlineMessage extends StatelessWidget {
  const OutlineMessage(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Space.m),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

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
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: scheme.outline),
      ),
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
