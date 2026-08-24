/// "Looks like a course export — sort it into chapters?"
///
/// Shown once per file when the trainer recognises a chapter layout in the
/// PGN, with the chapter list it would produce so the answer is an informed
/// one rather than a guess. Re-openable from the trainer header.
library;

import 'package:flutter/material.dart';

import '../../services/training/chapter_layout.dart';
import '../../theme/app_colors.dart';

/// Returns true to sort into chapters, false to keep one flat list, null if
/// the dialog was dismissed (ask again next time).
Future<bool?> showChapterSetupDialog(
  BuildContext context, {
  required ChapterLayoutProposal proposal,
  required bool chaptersCurrentlyOn,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) => _ChapterSetupDialog(
      proposal: proposal,
      chaptersOn: chaptersCurrentlyOn,
    ),
  );
}

class _ChapterSetupDialog extends StatelessWidget {
  final ChapterLayoutProposal proposal;
  final bool chaptersOn;

  const _ChapterSetupDialog({required this.proposal, required this.chaptersOn});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chapters = proposal.chapters;

    return AlertDialog(
      title: Text('Looks like ${proposal.formatLabel}'),
      // A *tight* width, not a max: [AlertDialog] wraps its content in an
      // [IntrinsicWidth], and asking a lazy viewport for its intrinsic width
      // throws ("RenderShrinkWrappingViewport does not support returning
      // intrinsic dimensions"). RenderConstrainedBox short-circuits that query
      // only when the width is tight, so a `maxWidth` here failed layout, left
      // the dialog's render box sizeless, and every later hit test threw —
      // which sticks MouseTracker in its device-update phase and kills pointer
      // input app-wide. Same reason [AddToStudyDialog] sizes its content box.
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(proposal.explanation, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            Text(
              'Sort ${proposal.groupedLineCount} lines into these '
              '${proposal.chapterCount} chapters?',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Scrollbar(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: chapters.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, indent: 12, endIndent: 12),
                    itemBuilder: (context, index) {
                      final chapter = chapters[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                chapter.name,
                                style: theme.textTheme.bodyMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              '${chapter.lineCount} line'
                              '${chapter.lineCount == 1 ? '' : 's'}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppColors.onSurfaceMuted,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            if (proposal.ungroupedLineCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${proposal.ungroupedLineCount} line'
                '${proposal.ungroupedLineCount == 1 ? '' : 's'} '
                'without a chapter title will sit under "Other lines".',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.onSurfaceMuted,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              'You can change this any time from "Chapters…" above the line '
              'list.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceMuted,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(chaptersOn ? 'Use one flat list' : 'Keep one flat list'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.auto_awesome_motion_outlined, size: 18),
          label: const Text('Sort into chapters'),
        ),
      ],
    );
  }
}
