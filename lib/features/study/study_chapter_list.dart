import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import '../../chess/pgn/study.dart';
import '../../ui/row_actions.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';

typedef ChapterActions = ({
  VoidCallback rename,
  VoidCallback tags,
  VoidCallback root,
  VoidCallback clearAnnotations,
  VoidCallback clearVariations,
  void Function(Side orientation) face,
  void Function(int by) move,
  VoidCallback copyPgn,
  VoidCallback remove,
  VoidCallback moveTo,
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
    this.dragHandle,
  });

  final StudyChapter chapter;

  /// This is the chapter on the board.
  final bool open;

  final bool busy;
  final VoidCallback onOpen;
  final ChapterActions actions;
  final Widget? dragHandle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      selected: open,
      child: Material(
        color: open ? theme.colorScheme.surfaceContainerHighest : null,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.xs, 0),
            child: SizedBox(
              height: listRowHeight,
              child: Row(
                children: [
                  dragHandle ??
                      SizedBox(
                        width: Space.l + Space.xs,
                        child: Text(
                          '${chapter.ordinal}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                  Expanded(
                    child: Tooltip(
                      message: chapter.name,
                      child: Text(
                        chapter.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  RowActions(tooltip: 'Chapter actions', children: _menuItems),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> get _menuItems => [
    rowAction('Rename…', actions.rename, busy: busy, icon: Icons.edit_outlined),
    rowAction('PGN tags…', actions.tags, busy: busy),
    rowAction('Set starting position…', actions.root, busy: busy),
    const Divider(),
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
    const Divider(),
    rowAction('Move to position…', actions.moveTo, busy: busy),
    rowAction(
      'Move up',
      () => actions.move(-1),
      busy: busy,
      icon: Icons.arrow_upward,
    ),
    rowAction(
      'Move down',
      () => actions.move(1),
      busy: busy,
      icon: Icons.arrow_downward,
    ),
    const Divider(),
    rowAction(
      'Copy chapter PGN',
      actions.copyPgn,
      busy: busy,
      icon: Icons.content_copy,
    ),
    const Divider(),
    rowAction(
      'Clear comments, glyphs and shapes…',
      actions.clearAnnotations,
      busy: busy,
    ),
    rowAction('Clear variations…', actions.clearVariations, busy: busy),
    rowAction(
      'Delete chapter…',
      actions.remove,
      busy: busy,
      icon: Icons.delete_outline,
    ),
  ];
}

/// Chapter search never hides the current study or changes its chapter numbers.
class StudyChapterList extends StatefulWidget {
  const StudyChapterList({
    super.key,
    required this.chapters,
    required this.active,
    required this.busy,
    required this.onOpen,
    required this.actionsFor,
    required this.onReorder,
  });
  final List<StudyChapter> chapters;
  final int? active;
  final bool busy;
  final ValueChanged<int> onOpen;
  final ChapterActions Function(StudyChapter) actionsFor;
  final void Function(int from, int to) onReorder;
  @override
  State<StudyChapterList> createState() => _StudyChapterListState();
}

class _StudyChapterListState extends State<StudyChapterList> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';
  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(StudyChapterList old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active) _reveal();
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted || !_scroll.hasClients || _query.isNotEmpty) return;
    final offset = (widget.active ?? 0) * listRowHeight;
    final position = _scroll.position;
    if (offset < position.pixels ||
        offset + listRowHeight > position.pixels + position.viewportDimension) {
      _scroll.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
    }
  });
  @override
  Widget build(BuildContext context) {
    final chapters = widget.chapters
        .where((c) => c.name.toLowerCase().contains(_query))
        .toList();
    final canDrag = _query.isEmpty && !widget.busy;
    Widget row(int index) {
      final chapter = chapters[index];
      return ChapterRow(
        key: ValueKey(chapter.index),
        chapter: chapter,
        open: widget.active == chapter.index,
        busy: widget.busy,
        onOpen: () => widget.onOpen(chapter.index),
        actions: widget.actionsFor(chapter),
        dragHandle: canDrag
            ? ReorderableDragStartListener(
                index: index,
                child: Tooltip(
                  message: 'Drag to reorder',
                  child: SizedBox(
                    width: Space.l + Space.xs,
                    child: Text(
                      '${chapter.ordinal}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
              )
            : null,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.s, Space.s),
          child: SearchField(
            controller: _search,
            hint: 'Search chapters',
            onChanged: (value) =>
                setState(() => _query = value.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: chapters.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(Space.l),
                  child: Text('Nothing matches in this study.'),
                )
              : canDrag
              ? ReorderableListView.builder(
                  scrollController: _scroll,
                  buildDefaultDragHandles: false,
                  itemCount: chapters.length,
                  itemExtent: listRowHeight,
                  itemBuilder: (_, index) => row(index),
                  onReorder: (from, to) {
                    widget.onReorder(from, to > from ? to - 1 : to);
                  },
                )
              : ListView.builder(
                  controller: _scroll,
                  itemExtent: listRowHeight,
                  itemCount: chapters.length,
                  itemBuilder: (_, index) => row(index),
                ),
        ),
      ],
    );
  }
}
