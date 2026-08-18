/// Persistent chapter sidebar for Study mode, modeled on Lichess studies:
/// every chapter is always visible in a left-hand column — click a row to
/// switch, drag the ordinal to reorder, gear for chapter actions, and a
/// pinned "New chapter" footer. The filter box narrows big course imports
/// (reordering is disabled while filtering, since row indices no longer
/// match chapter indices).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/study_controller.dart';
import '../../theme/app_colors.dart';

class StudyChapterSidebar extends StatefulWidget {
  final StudyController study;

  /// Chapter actions that need the screen's dialogs.
  final VoidCallback onAddChapter;
  final VoidCallback onAddChapterFromPosition;
  final ValueChanged<int> onRenameChapter;
  final ValueChanged<int> onSetStartingPosition;
  final ValueChanged<int> onDeleteChapter;

  const StudyChapterSidebar({
    super.key,
    required this.study,
    required this.onAddChapter,
    required this.onAddChapterFromPosition,
    required this.onRenameChapter,
    required this.onSetStartingPosition,
    required this.onDeleteChapter,
  });

  @override
  State<StudyChapterSidebar> createState() => _StudyChapterSidebarState();
}

class _StudyChapterSidebarState extends State<StudyChapterSidebar> {
  static const double _rowHeight = 34;

  final TextEditingController _filter = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// Last chapter index this sidebar scrolled into view, so an externally
  /// driven switch (keyboard, handoff) reveals the new active row without
  /// re-scrolling on every unrelated rebuild.
  int _revealedIndex = -1;

  @override
  void dispose() {
    _filter.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _filtering => _filter.text.trim().isNotEmpty;

  List<int> _visibleIndices() {
    final chapters = widget.study.doc.chapters;
    if (!_filtering) return [for (var i = 0; i < chapters.length; i++) i];
    final query = _filter.text.trim().toLowerCase();
    return [
      for (var i = 0; i < chapters.length; i++)
        if (chapters[i].name.toLowerCase().contains(query)) i,
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

  void _onReorder(int oldRow, int newRow) {
    widget.study.reorderChapter(oldRow, newRow);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chapters = widget.study.doc.chapters;
    final visible = _visibleIndices();
    _revealActive(visible);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Text(
            'Chapters (${chapters.length})',
            style: theme.textTheme.titleSmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: TextField(
            controller: _filter,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 12),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Filter chapters',
              hintStyle: const TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceMuted,
              ),
              prefixIcon: const Icon(Icons.search, size: 15),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 28,
                minHeight: 24,
              ),
              suffixIcon: _filtering
                  ? IconButton(
                      icon: const Icon(Icons.close, size: 14),
                      tooltip: 'Clear filter',
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        _filter.clear();
                        setState(() {});
                      },
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 6,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? const Center(
                  child: Text(
                    'No matching chapters',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurfaceMuted,
                    ),
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
                  onReorderItem: _onReorder,
                  itemBuilder: (context, row) => _buildRow(
                    row,
                    key: ObjectKey(chapters[row]),
                    canReorder: chapters.length > 1,
                  ),
                ),
        ),
        const Divider(height: 1),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text(
                  'New chapter',
                  style: TextStyle(fontSize: 12),
                ),
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                onPressed: widget.onAddChapter,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.dashboard_customize_outlined, size: 16),
              tooltip: 'New chapter from a custom position…',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onAddChapterFromPosition,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ],
    );
  }

  Widget _buildRow(int index, {required Key? key, required bool canReorder}) {
    final theme = Theme.of(context);
    final chapter = widget.study.doc.chapters[index];
    final active = index == widget.study.chapterIndex;
    final result = chapter.headers['Result'];
    final showResult = result != null && result.isNotEmpty && result != '*';

    final ordinal = Text(
      '${index + 1}',
      textAlign: TextAlign.right,
      style: const TextStyle(fontSize: 11, color: AppColors.onSurfaceDim),
    );

    return InkWell(
      key: key,
      onTap: () => widget.study.selectChapter(index),
      child: Container(
        height: _rowHeight,
        padding: const EdgeInsets.only(left: 8),
        color: active ? AppColors.accent.withValues(alpha: 0.14) : null,
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
              child: Text(
                chapter.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: active ? AppColors.ink : AppColors.onSurfaceSoft,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (showResult)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  result,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: AppColors.onSurfaceDim,
                  ),
                ),
              ),
            PopupMenuButton<String>(
              icon: Icon(
                Icons.settings,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.55,
                ),
              ),
              tooltip: 'Chapter actions',
              padding: EdgeInsets.zero,
              onSelected: (action) {
                switch (action) {
                  case 'rename':
                    widget.onRenameChapter(index);
                  case 'position':
                    widget.onSetStartingPosition(index);
                  case 'delete':
                    widget.onDeleteChapter(index);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename chapter…')),
                PopupMenuItem(
                  value: 'position',
                  child: Text('Set starting position…'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(value: 'delete', child: Text('Delete chapter…')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
