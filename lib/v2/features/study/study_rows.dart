import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/pgn/study.dart';
import '../../storage/chapter_files.dart';
import '../../ui/row_actions.dart';
import '../../ui/theme.dart';

/// One study in the list. The open one is highlighted and its chapters are
/// listed under it.
class StudyRow extends StatelessWidget {
  const StudyRow({
    super.key,
    required this.study,
    required this.open,
    required this.busy,
    required this.onOpen,
    required this.onCopyPgn,
    required this.onDelete,
  });

  final ChapterRef study;

  /// This is the study the workspace has open.
  final bool open;

  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onCopyPgn;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: open ? scheme.surfaceContainerHighest : Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.s, 0, Space.xs, 0),
          child: SizedBox(
            height: listRowHeight,
            child: Row(
              children: [
                Expanded(
                  child: Text(study.name, overflow: TextOverflow.ellipsis),
                ),
                RowActions(
                  children: [
                    // Only the open study's text is in hand; another one
                    // would have to be read from disk first.
                    rowAction('Copy study PGN', onCopyPgn, busy: busy || !open),
                    rowAction('Delete study…', onDelete, busy: busy),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a chapter row's menu can ask for.
typedef ChapterActions = ({
  VoidCallback rename,
  void Function(Side orientation) face,
  void Function(int by) move,
  VoidCallback copyPgn,
  VoidCallback remove,
});

/// One chapter of the open study: its place in the file, its name, and the
/// operations that change it.
class ChapterRow extends StatelessWidget {
  const ChapterRow({
    super.key,
    required this.chapter,
    required this.open,
    required this.busy,
    required this.onOpen,
    required this.actions,
  });

  final StudyChapter chapter;

  /// This is the chapter on the board.
  final bool open;

  final bool busy;
  final VoidCallback onOpen;
  final ChapterActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: open ? theme.colorScheme.surfaceContainerHighest : null,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.xs, 0),
          child: SizedBox(
            height: listRowHeight,
            child: Row(
              children: [
                SizedBox(
                  width: Space.l + Space.xs,
                  child: Text(
                    '${chapter.ordinal}',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                Expanded(
                  child: Text(chapter.name, overflow: TextOverflow.ellipsis),
                ),
                RowActions(
                  tooltip: 'Chapter actions',
                  children: [
                    rowAction('Rename…', actions.rename, busy: busy),
                    rowAction(
                      'Face White',
                      () => actions.face(Side.white),
                      busy: busy || chapter.orientation == Side.white,
                    ),
                    rowAction(
                      'Face Black',
                      () => actions.face(Side.black),
                      busy: busy || chapter.orientation == Side.black,
                    ),
                    rowAction('Move up', () => actions.move(-1), busy: busy),
                    rowAction('Move down', () => actions.move(1), busy: busy),
                    rowAction('Copy chapter PGN', actions.copyPgn, busy: busy),
                    rowAction('Delete chapter…', actions.remove, busy: busy),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
