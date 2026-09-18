/// Shared chapter list for the Study sidebar and chapter manager:
/// every chapter is always visible in a left-hand column — click a row to
/// switch, drag the ordinal to reorder, and open the row menu for chapter actions.
/// "New chapter" sits above the list. The filter box narrows big course imports
/// (reordering is disabled while filtering, since row indices no longer
/// match chapter indices).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../design_system/components/item_title.dart';

import '../../features/studies/controllers/study_controller.dart';
import '../../features/studies/models/study_projection.dart';
import '../../features/studies/widgets/study_selector.dart';
import '../../design_system/theme/app_typography.dart';
import '../../l10n/generated/app_localizations.dart';
import 'study_chapter_actions.dart';
import '../../design_system/components/list_search_field.dart';

class StudyChapterSidebar extends StatefulWidget {
  final StudyController study;

  /// Chapter actions that need the screen's dialogs.
  final VoidCallback? onAddChapter;
  final bool inlineActions;
  final void Function(ChapterAction, int) onChapterAction;

  const StudyChapterSidebar({
    super.key,
    required this.study,
    this.onAddChapter,
    this.inlineActions = false,
    required this.onChapterAction,
  });

  @override
  State<StudyChapterSidebar> createState() => _StudyChapterSidebarState();
}

class _StudyChapterSidebarState extends State<StudyChapterSidebar> {
  double get _rowHeight =>
      (widget.inlineActions ? 52 : 34) *
      MediaQuery.textScalerOf(context).scale(14) /
      14;

  String _filter = '';
  final ScrollController _scroll = ScrollController();

  /// Last chapter index this sidebar scrolled into view, so an externally
  /// driven switch (keyboard, handoff) reveals the new active row without
  /// re-scrolling on every unrelated rebuild.
  int _revealedIndex = -1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool get _filtering => _filter.trim().isNotEmpty;

  List<int> _visibleIndices() {
    final chapters = widget.study.chapterList.chapters;
    if (!_filtering) return [for (var i = 0; i < chapters.length; i++) i];
    return [
      for (var i = 0; i < chapters.length; i++)
        if (matchesSearch(_filter, chapters[i].name)) i,
    ];
  }

  /// Keep the active row visible, Lichess-style: scroll only when the active
  /// chapter changed and only as far as needed.
  void _revealActive(List<int> visible) {
    final active = widget.study.chapterIndex;
    if (active == _revealedIndex) return;
    _revealedIndex = active;
    final row = visible.indexOf(active);
    if (row == -1) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final top = row * _rowHeight;
      final bottom = top + _rowHeight;
      final viewTop = _scroll.offset;
      final viewBottom = viewTop + _scroll.position.viewportDimension;
      double? target;
      if (top < viewTop) {
        target = top;
      } else if (bottom > viewBottom) {
        target = bottom - _scroll.position.viewportDimension;
      }
      if (target != null) {
        unawaited(
          _scroll.animateTo(
            target.clamp(0, _scroll.position.maxScrollExtent),
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  int _indexOf(Object chapterKey) => mounted
      ? widget.study.chapterList.chapters.indexWhere(
          (chapter) => chapter.key == chapterKey,
        )
      : -1;

  void _act(ChapterAction action, Object chapterKey) {
    final index = _indexOf(chapterKey);
    if (index >= 0) widget.onChapterAction(action, index);
  }

  void _select(Object chapterKey) {
    final index = _indexOf(chapterKey);
    if (index >= 0) widget.study.selectChapter(index);
  }

  @override
  Widget build(BuildContext context) =>
      StudySelector<(StudyChapterListProjection, int)>(
        study: widget.study,
        select: (study) => (study.chapterList, study.chapterIndex),
        builder: (context, _) => _buildList(context),
      );

  Widget _buildList(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final list = widget.study.chapterList;
    final chapters = list.chapters;
    final visible = _visibleIndices();
    _revealActive(visible);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Text(
            l10n.studyChapterListTitle(chapters.length),
            style: theme.textTheme.titleSmall,
          ),
        ),
        if (widget.onAddChapter != null)
          TextButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: Text(l10n.studyNewChapter),
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onPressed: widget.onAddChapter,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: ListSearchField(
            hintText: l10n.studySearchChapters,
            clearLabel: l10n.clearSearch,
            onChanged: (value) {
              if (!mounted) return;
              setState(() {
                _filter = value;
                _revealedIndex = -1;
              });
            },
          ),
        ),
        if (widget.inlineActions)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              _filtering ? l10n.studyFilteredReorder : l10n.studyDragReorder,
              style: AppTypography.caption(context),
            ),
          ),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    l10n.studyNoMatchingChapters,
                    style: AppTypography.caption(context),
                  ),
                )
              // Reordering needs row == chapter index, so the filtered list
              // falls back to a plain (non-reorderable) list.
              : _filtering
              ? ListView.builder(
                  controller: _scroll,
                  itemExtent: _rowHeight,
                  itemCount: visible.length,
                  itemBuilder: (context, row) =>
                      _buildRow(visible[row], key: null, canReorder: false),
                )
              : ReorderableListView.builder(
                  scrollController: _scroll,
                  itemExtent: _rowHeight,
                  itemCount: visible.length,
                  buildDefaultDragHandles: false,
                  // onReorderItem, unlike the deprecated onReorder, already
                  // accounts for the dragged row being lifted out of the list.
                  onReorderItem: (oldIndex, newIndex) {
                    if (!mounted ||
                        !identical(widget.study.chapterList, list)) {
                      return;
                    }
                    widget.study.reorderChapter(oldIndex, newIndex);
                  },
                  itemBuilder: (context, row) => _buildRow(
                    row,
                    key: ObjectKey(chapters[row].key),
                    canReorder: chapters.length > 1,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildRow(int index, {required Key? key, required bool canReorder}) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final chapter = widget.study.chapterList.chapters[index];
    final active = index == widget.study.chapterIndex;
    final result = chapter.result;
    final showResult = result != null && result.isNotEmpty && result != '*';

    final ordinal = Text(
      '${index + 1}',
      textAlign: TextAlign.right,
      style: AppTypography.caption(context),
    );

    return InkWell(
      key: key,
      onTap: () => _select(chapter.key),
      child: Container(
        height: _rowHeight,
        padding: const EdgeInsets.only(left: 8),
        color: active ? theme.colorScheme.primaryContainer : null,
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: canReorder
                  ? ReorderableDragStartListener(
                      index: index,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: ordinal,
                      ),
                    )
                  : ordinal,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ItemTitle(
                    chapter.name,
                    maxLines: 1,
                    style: AppTypography.secondary(context).copyWith(
                      color: active
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurface,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (widget.inlineActions && active)
                    Text(
                      l10n.studyChapterOpenNow,
                      style: AppTypography.caption(context),
                    ),
                ],
              ),
            ),
            if (showResult)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(result, style: AppTypography.caption(context)),
              ),
            if (widget.inlineActions) ...[
              IconButton(
                tooltip: l10n.studyEditChapter,
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: () => _act(ChapterAction.edit, chapter.key),
              ),
              IconButton(
                tooltip: widget.study.chapterList.chapters.length > 1
                    ? l10n.studyDeleteChapter
                    : l10n.studyKeepOneChapter,
                icon: const Icon(Icons.delete_outline, size: 18),
                color: theme.colorScheme.error,
                onPressed: widget.study.chapterList.chapters.length > 1
                    ? () => _act(ChapterAction.delete, chapter.key)
                    : null,
              ),
            ] else
              PopupMenuButton<ChapterAction>(
                icon: Icon(
                  Icons.more_horiz,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                tooltip: l10n.studyChapterActions,
                padding: EdgeInsets.zero,
                onSelected: (action) => _act(action, chapter.key),
                itemBuilder: (_) => studyChapterMenuItems(
                  context,
                  canDelete: widget.study.chapterList.chapters.length > 1,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
