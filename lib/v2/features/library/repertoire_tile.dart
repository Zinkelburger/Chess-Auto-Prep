import 'package:flutter/material.dart';

import '../../storage/chapter_files.dart';
import '../../ui/choice_dialog.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/name_dialog.dart';
import '../../ui/relative_time.dart';
import '../../ui/row_actions.dart';
import '../../ui/theme.dart';
import 'library.dart';
import 'library_messages.dart';

/// One repertoire in the list, and its chapters when it is open.
class RepertoireTile extends StatelessWidget {
  const RepertoireTile({
    super.key,
    required this.library,
    required this.folder,
    required this.expanded,
    required this.onToggle,
    required this.selected,
    required this.onOpen,
  });

  final Library library;
  final RepertoireFolder folder;
  final bool expanded;
  final VoidCallback onToggle;
  final ChapterRef? selected;
  final ValueChanged<ChapterRef> onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RepertoireRow(
          library: library,
          folder: folder,
          expanded: expanded,
          onToggle: onToggle,
        ),
        if (expanded)
          for (final chapter in folder.chapters)
            _ChapterRow(
              library: library,
              chapter: chapter,
              open: chapter == selected,
              onOpen: () => onOpen(chapter),
            ),
      ],
    );
  }
}

class _RepertoireRow extends StatelessWidget {
  const _RepertoireRow({
    required this.library,
    required this.folder,
    required this.expanded,
    required this.onToggle,
  });

  final Library library;
  final RepertoireFolder folder;
  final bool expanded;
  final VoidCallback onToggle;

  String get _subtitle {
    final chapters = folder.chapters.length;
    final counted = chapters == 1 ? '1 chapter' : '$chapters chapters';
    return '$counted · Modified ${relativeTime(folder.modified)}';
  }

  Future<void> _rename(BuildContext context) async {
    final name = await showNameDialog(
      context,
      title: 'Rename repertoire',
      label: 'Repertoire name',
      confirm: 'Rename',
      initial: folder.name,
    );
    if (name == null || name == folder.name || !context.mounted) return;
    await announce(
      context,
      library.renameRepertoire(folder, name),
      thing: 'repertoire',
      name: name,
      failed: 'Could not rename the repertoire.',
    );
  }

  Future<void> _newChapter(BuildContext context) async {
    final name = await showNameDialog(
      context,
      title: 'New chapter',
      label: 'Chapter name',
      confirm: 'Create',
    );
    if (name == null || !context.mounted) return;
    await announce(
      context,
      library.createChapter(folder, name),
      thing: 'chapter',
      name: name,
      failed: 'Could not create the chapter.',
    );
  }

  Future<void> _delete(BuildContext context) async {
    final yes = await confirmAction(
      context,
      title: 'Delete repertoire "${folder.name}"?',
      message:
          'Its chapters can be restored from Deleted chapters under this '
          'list.',
      confirm: 'Delete',
    );
    if (!yes || !context.mounted) return;
    await announce(
      context,
      library.deleteRepertoire(folder),
      thing: 'repertoire',
      name: folder.name,
      failed: 'Could not delete the repertoire.',
    );
  }

  /// What can be done to the repertoire itself, off while a catalog change
  /// is in flight.
  List<Widget> _actions(BuildContext context) => [
    rowAction('Rename…', () => _rename(context), busy: !library.canChange),
    rowAction(
      'New chapter…',
      () => _newChapter(context),
      busy: !library.canChange,
    ),
    rowAction('Delete…', () => _delete(context), busy: !library.canChange),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.s,
          Space.xs,
          Space.xs,
          Space.xs,
        ),
        child: Row(
          children: [
            Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
              size: IconSize.action,
            ),
            const SizedBox(width: Space.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(folder.name, overflow: TextOverflow.ellipsis),
                  Text(_subtitle, style: text.labelSmall),
                ],
              ),
            ),
            RowActions(children: _actions(context)),
          ],
        ),
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.library,
    required this.chapter,
    required this.open,
    required this.onOpen,
  });

  final Library library;
  final ChapterRef chapter;

  /// This is the chapter the workspace has open.
  final bool open;

  final VoidCallback onOpen;

  Future<void> _rename(BuildContext context) async {
    final name = await showNameDialog(
      context,
      title: 'Rename chapter',
      label: 'Chapter name',
      confirm: 'Rename',
      initial: chapter.name,
    );
    if (name == null || name == chapter.name || !context.mounted) return;
    await announce(
      context,
      library.renameChapter(chapter, name),
      thing: 'chapter',
      name: name,
      failed: 'Could not rename the chapter.',
      reload: library.reloadOpenChapter,
    );
  }

  /// The repertoires this chapter is not already in, picked from a searchable
  /// list rather than a menu of every one of them.
  Future<void> _move(BuildContext context) async {
    final to = await showChoiceDialog<RepertoireFolder>(
      context,
      title: 'Move "${chapter.name}" to',
      options: [
        for (final folder in library.repertoires)
          if (folder.name != chapter.repertoire) folder,
      ],
      label: (folder) => folder.name,
      hint: 'Search repertoires',
      empty: 'There is no other repertoire to move it to.',
    );
    if (to == null || !context.mounted) return;
    await announce(
      context,
      library.moveChapter(chapter, to),
      thing: 'chapter',
      name: chapter.name,
      failed: 'Could not move the chapter.',
      reload: library.reloadOpenChapter,
    );
  }

  Future<void> _delete(BuildContext context) async {
    final yes = await confirmAction(
      context,
      title: 'Delete chapter "${chapter.name}"?',
      message: library.sharesFile(chapter)
          ? 'Its games, including edits you have just made, will be taken '
                'out of the course file they share.'
          : 'The chapter, including edits you have just made, can be '
                'restored from Deleted chapters under this list.',
      confirm: 'Delete',
    );
    if (!yes || !context.mounted) return;
    await announce(
      context,
      library.deleteChapter(chapter),
      thing: 'chapter',
      name: chapter.name,
      failed: 'Could not delete the chapter.',
      reload: library.reloadOpenChapter,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: open ? scheme.surfaceContainerHighest : Colors.transparent,
      child: InkWell(
        onTap: library.canChange ? onOpen : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.l + Space.m,
            Space.xs,
            Space.xs,
            Space.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(chapter.name, overflow: TextOverflow.ellipsis),
              ),
              RowActions(
                children: [
                  rowAction(
                    'Rename…',
                    () => _rename(context),
                    busy: !library.canChange,
                  ),
                  rowAction(
                    'Move to…',
                    () => _move(context),
                    busy: !library.canChange,
                  ),
                  rowAction(
                    'Delete…',
                    () => _delete(context),
                    busy: !library.canChange,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
