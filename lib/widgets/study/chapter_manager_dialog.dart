/// One place to see every chapter in a study and put it in the right order.
///
/// The side-pane dropdown is for *switching* chapters; this is for *managing*
/// them — drag to reorder, rename and delete in the same visible row rather
/// than through a menu that acts on whichever chapter happens to be open.
library;

import 'package:flutter/material.dart';

import '../../core/study_controller.dart';
import '../../theme/app_colors.dart';

Future<void> showChapterManagerDialog(
  BuildContext context, {
  required StudyController study,
  required Future<String?> Function(String title, {String? initial}) promptName,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ChapterManagerDialog(study: study, promptName: promptName),
  );
}

class _ChapterManagerDialog extends StatefulWidget {
  const _ChapterManagerDialog({required this.study, required this.promptName});

  final StudyController study;
  final Future<String?> Function(String title, {String? initial}) promptName;

  @override
  State<_ChapterManagerDialog> createState() => _ChapterManagerDialogState();
}

class _ChapterManagerDialogState extends State<_ChapterManagerDialog> {
  StudyController get _study => widget.study;

  Future<void> _rename(int index) async {
    final name = await widget.promptName(
      'Rename chapter',
      initial: _study.doc.chapters[index].name,
    );
    if (name == null || !mounted) return;
    setState(() => _study.renameChapter(index, name));
  }

  Future<void> _delete(int index) async {
    if (_study.doc.chapters.length <= 1) return;
    final chapter = _study.doc.chapters[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete chapter "${chapter.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _study.deleteChapter(index));
  }

  @override
  Widget build(BuildContext context) {
    final chapters = _study.doc.chapters;
    final onlyOne = chapters.length <= 1;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
              child: Row(
                children: [
                  const Text(
                    'Chapters',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Drag to reorder',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Done',
                  ),
                ],
              ),
            ),
            const Divider(),
            Flexible(
              child: ReorderableListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: chapters.length,
                // onReorderItem, unlike the deprecated onReorder, already
                // accounts for the dragged row being lifted out of the list,
                // so these are final positions.
                onReorderItem: (oldIndex, newIndex) {
                  setState(() => _study.reorderChapter(oldIndex, newIndex));
                },
                itemBuilder: (context, index) {
                  final chapter = chapters[index];
                  final isCurrent = index == _study.chapterIndex;
                  return ListTile(
                    key: ValueKey('${chapter.name}#$index'),
                    dense: true,
                    leading: ReorderableDragStartListener(
                      index: index,
                      child: const Icon(
                        Icons.drag_indicator,
                        size: 20,
                        color: AppColors.onSurfaceMuted,
                      ),
                    ),
                    title: Text(
                      chapter.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: isCurrent
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    subtitle: isCurrent
                        ? const Text(
                            'Open now',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.onSurfaceMuted,
                            ),
                          )
                        : null,
                    onTap: () {
                      setState(() => _study.selectChapter(index));
                    },
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          tooltip: 'Rename chapter',
                          onPressed: () => _rename(index),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          color: AppColors.danger,
                          // A study must keep at least one chapter.
                          tooltip: onlyOne
                              ? 'A study needs at least one chapter'
                              : 'Delete chapter',
                          onPressed: onlyOne ? null : () => _delete(index),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
