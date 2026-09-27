/// An explicit preview of the trainer’s chapter grouping, opened from Material
/// settings. Applying it changes the list layout without rewriting the PGN.
library;

import 'package:flutter/material.dart';

import '../../design_system/components/item_title.dart';

import '../../features/training/models/chapter_layout.dart';
import '../../theme/app_colors.dart';

/// Returns true to sort into chapters, false to keep one flat list, null if
/// the dialog was dismissed without changing the grouping.
Future<bool?> showChapterSetupDialog(
  BuildContext context, {
  required ChapterLayoutProposal proposal,
  required bool chaptersCurrentlyOn,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) =>
        ChapterSetupPanel(proposal: proposal, chaptersOn: chaptersCurrentlyOn),
  );
}

class ChapterSetupPanel extends StatelessWidget {
  final ChapterLayoutProposal proposal;
  final bool chaptersOn;

  const ChapterSetupPanel({
    super.key,
    required this.proposal,
    required this.chaptersOn,
    this.embedded = false,
    this.onChoose,
  });
  final bool embedded;
  final ValueChanged<bool>? onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chapters = proposal.chapters;

    final dialog = AlertDialog(
      scrollable: true,
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
            SizedBox(
              height: 300,
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
                              child: ItemTitle(
                                chapter.name,
                                style: theme.textTheme.bodyMedium,
                                maxLines: 2,
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
              'This changes the trainer’s list only, not the PGN file. You can '
              'return here from Training settings.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceMuted,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => embedded
              ? onChoose?.call(false)
              : Navigator.of(context).pop(false),
          child: Text(chaptersOn ? 'Use one flat list' : 'Keep one flat list'),
        ),
        FilledButton.icon(
          onPressed: () =>
              embedded ? onChoose?.call(true) : Navigator.of(context).pop(true),
          icon: const Icon(Icons.auto_awesome_motion_outlined, size: 18),
          label: const Text('Sort into chapters'),
        ),
      ],
    );
    if (!embedded) return dialog;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          dialog.content!,
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: dialog.actions!),
        ],
      ),
    );
  }
}
