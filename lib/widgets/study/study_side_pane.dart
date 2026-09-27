/// Engine + chapter bar + PGN editor for Study mode.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import '../../design_system/theme/app_typography.dart';
import '../../l10n/generated/app_localizations.dart';
import 'package:flutter/services.dart';

import '../../features/studies/controllers/study_controller.dart';
import '../../features/studies/widgets/study_selector.dart';
import '../../features/studies/models/study_projection.dart';
import '../../chess_core/moves/tree_path.dart';
import '../../chess_core/moves/move_tree_snapshot.dart';
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
    required this.onChapterAction,
  });

  final StudyController study;
  final bool compact;
  final void Function(List<String> sanMoves, int clickedIndex) onEngineLine;
  final VoidCallback onAddChapter;
  final VoidCallback onPickChapter;
  final VoidCallback onManageChapters;
  final void Function(ChapterAction, int) onChapterAction;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        StudySelector<(String, bool)>(
          study: study,
          select: (owner) => (owner.cursor.position.fen, owner.cursor.flipped),
          builder: (context, view) => InlineEngineBar(
            fen: view.$1,
            previewFlipped: view.$2,
            onLineMoveTapped: onEngineLine,
          ),
        ),
        const Divider(height: 1),
        if (compact) ...[
          _CompactChapterBar(
            study: study,
            onAddChapter: onAddChapter,
            onPickChapter: onPickChapter,
            onManageChapters: onManageChapters,
            onChapterAction: onChapterAction,
          ),
          const Divider(height: 8),
        ] else
          const SizedBox(height: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: StudySelector<(MoveTreeSnapshot, TreePath)>(
              study: study,
              select: (owner) => (owner.tree, owner.path),
              builder: (context, view) => InteractivePgnEditor(
                tree: view.$1,
                currentPath: view.$2,
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
    required this.onChapterAction,
  });

  final StudyController study;
  final VoidCallback onAddChapter;
  final VoidCallback onPickChapter;
  final VoidCallback onManageChapters;
  final void Function(ChapterAction, int) onChapterAction;

  @override
  Widget build(BuildContext context) =>
      StudySelector<(StudyChapterListProjection, int)>(
        study: study,
        select: (owner) => (owner.chapterList, owner.chapterIndex),
        builder: (context, _) => _buildBar(context),
      );

  Widget _buildBar(BuildContext context) {
    final theme = Theme.of(context);
    final chapter = study.chapterList.chapters[study.chapterIndex];
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
                        study.chapterList.chapters.isEmpty
                            ? AppLocalizations.of(context).studyNoChapters
                            : study
                                  .chapterList
                                  .chapters[study.chapterIndex]
                                  .name,
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
            tooltip: AppLocalizations.of(context).studyNewChapter,
            visualDensity: VisualDensity.compact,
            onPressed: onAddChapter,
          ),
          PopupMenuButton<Object>(
            key: ObjectKey(chapter.key),
            tooltip: AppLocalizations.of(context).studyChapterActions,
            onSelected: (action) {
              if (!context.mounted) return;
              if (action is! ChapterAction) {
                onManageChapters();
                return;
              }
              final current = study.chapterList.chapters.indexWhere(
                (item) => item.key == chapter.key,
              );
              if (current >= 0) onChapterAction(action, current);
            },
            itemBuilder: (_) => [
              PopupMenuItem<Object>(
                value: _manageChapters,
                child: Text(AppLocalizations.of(context).studyManageChapters),
              ),
              const PopupMenuDivider(),
              ...studyChapterMenuItems(
                context,
                canDelete: study.chapterList.chapters.length > 1,
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    AppLocalizations.of(context).studyChapter,
                    style: AppTypography.secondary(context),
                  ),
                  const Icon(Icons.arrow_drop_down, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
