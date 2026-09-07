/// Engine + chapter bar + PGN editor for Study mode.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/study_controller.dart';
import '../../utils/app_messages.dart';
import '../engine/inline_engine_bar.dart';
import '../interactive_pgn_editor.dart';
import 'study_chapter_actions.dart';

class StudySidePane extends StatelessWidget {
  const StudySidePane({
    super.key,
    required this.study,
    required this.compact,
    required this.onEngineLine,
    required this.onAddChapter,
    required this.onPickChapter,
    required this.onManageChapters,
    required this.actions,
  });

  final StudyController study;
  final bool compact;
  final void Function(List<String> sanMoves, int clickedIndex) onEngineLine;
  final VoidCallback onAddChapter;
  final VoidCallback onPickChapter;
  final VoidCallback onManageChapters;
  final StudyChapterActions actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InlineEngineBar(
          fen: study.currentPosition.fen,
          previewFlipped: study.flipped,
          onLineMoveTapped: onEngineLine,
        ),
        const Divider(height: 1),
        if (compact) ...[
          _CompactChapterBar(
            study: study,
            onAddChapter: onAddChapter,
            onPickChapter: onPickChapter,
            onManageChapters: onManageChapters,
            actions: actions,
          ),
          const Divider(height: 8),
        ] else
          const SizedBox(height: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: InteractivePgnEditor(
              tree: study.tree,
              currentPath: study.path,
              showAnnotationPanel: true,
              onJump: study.jump,
              onCommentChanged: study.setComment,
              onToggleNag: study.toggleNag,
              onDelete: study.deleteAt,
              onPromote: study.promote,
              onMakeMainLine: study.makeMainLine,
              onCopyToClipboard: (text, message) {
                unawaited(Clipboard.setData(ClipboardData(text: text)));
                showAppSnackBar(context, message);
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Manage-and-reorder sits above the shared per-chapter menu.  It needs a
/// value of its own: a null menu value reads as "dismissed" to
/// [PopupMenuButton] and never reaches `onSelected`.
const _manageChapters = 'manage';

class _CompactChapterBar extends StatelessWidget {
  const _CompactChapterBar({
    required this.study,
    required this.onAddChapter,
    required this.onPickChapter,
    required this.onManageChapters,
    required this.actions,
  });

  final StudyController study;
  final VoidCallback onAddChapter;
  final VoidCallback onPickChapter;
  final VoidCallback onManageChapters;
  final StudyChapterActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
      child: Row(
        children: [
          Icon(
            Icons.bookmark_outline,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: onPickChapter,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        study.doc.chapters.isEmpty
                            ? 'No chapters'
                            : study.doc.chapters[study.chapterIndex].name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, size: 20),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            tooltip: 'New chapter',
            visualDensity: VisualDensity.compact,
            onPressed: onAddChapter,
          ),
          PopupMenuButton<Object>(
            icon: const Icon(Icons.more_vert, size: 18),
            tooltip: 'Chapter actions',
            onSelected: (action) => action is ChapterAction
                ? actions.run(action, study.chapterIndex)
                : onManageChapters(),
            itemBuilder: (_) => [
              const PopupMenuItem<Object>(
                value: _manageChapters,
                child: Text('Manage & reorder chapters…'),
              ),
              const PopupMenuDivider(),
              ...StudyChapterActions.menuItems(
                canDelete: study.doc.chapters.length > 1,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
