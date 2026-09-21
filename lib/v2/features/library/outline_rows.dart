import 'package:flutter/material.dart';

import '../../storage/chapter_files.dart';
import '../../ui/row_actions.dart';
import '../../ui/theme.dart';
import 'chapter_outline.dart';

/// One chapter of the outline. The one on the board is bold and accented, as
/// the old app's is, because it is where every other panel is pointing.
class ChapterRow extends StatelessWidget {
  const ChapterRow({super.key, required this.chapter, required this.onOpen});

  final OutlineChapter chapter;
  final ValueChanged<ChapterRef> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onOpen(chapter.ref),
      child: SizedBox(
        height: outlineRowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.m),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  chapter.name,
                  overflow: TextOverflow.ellipsis,
                  style: chapter.open
                      ? TextStyle(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.primary,
                        )
                      : null,
                ),
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
          ),
        ),
      ),
    );
  }
}

/// One line of the open chapter: what it is called, where it starts, and the
/// menu of what can be done to it.
class LineRow extends StatelessWidget {
  const LineRow({
    super.key,
    required this.line,
    required this.current,
    required this.onTap,
    required this.actions,
  });

  final OutlineLine line;

  /// The cursor is on one of this line's moves.
  final bool current;

  final VoidCallback onTap;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: current
          ? theme.colorScheme.surfaceContainerHighest
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: outlineRowHeight,
          child: Padding(
            padding: const EdgeInsets.only(left: Space.m + outlineIndent),
            child: Row(
              children: [
                if (!line.shared) ...[
                  Flexible(
                    child: Text(line.name, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: Space.s),
                ],
                Expanded(
                  child: Text(
                    line.moves,
                    overflow: TextOverflow.ellipsis,
                    style: monoText.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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
