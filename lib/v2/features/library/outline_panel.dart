import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../storage/chapter_files.dart';
import '../../ui/choice_dialog.dart';
import '../../ui/name_dialog.dart';
import '../../ui/row_actions.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import '../../workspace/chapter_commands.dart';
import '../../workspace/document_session.dart';
import '../../workspace/undo_notice.dart';
import 'chapter_outline.dart';
import 'library.dart';
import 'library_messages.dart';
import 'new_chapter_dialog.dart';

/// The chapters of the open repertoire and, under the open one, its lines.
///
/// Clicking a chapter opens it; clicking a line puts the cursor on its last
/// move. Ctrl-click and Shift-click pick several lines, and picked lines go
/// together: dragged onto a chapter they become lines of it, dragged onto a
/// line they fold into it as variations, and the `⋯` menu moves them to a
/// chapter by name. That is also how proposed lines are accepted. The line
/// a line's `⋯` menu acts on is that line, never the cursor's.
class OutlinePanel extends StatefulWidget {
  const OutlinePanel({
    super.key,
    required this.outline,
    required this.library,
    required this.session,
    required this.onOpen,
  });

  final ChapterOutline outline;
  final Library library;
  final DocumentSession session;

  /// Opening a chapter is the host's, because it has to ask about a draft
  /// the file never took first.
  final ValueChanged<ChapterRef> onOpen;

  @override
  State<OutlinePanel> createState() => _OutlinePanelState();
}

class _OutlinePanelState extends State<OutlinePanel> {
  final _search = TextEditingController();

  /// The lines picked with Ctrl or Shift, by game. Empty means whatever row
  /// the pointer is on is the one that moves.
  var _selected = <int>{};

  /// Where a Shift-click extends from: the last line clicked plainly or
  /// with Ctrl.
  int? _anchor;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// A chapter made with the board on a position can start there: that is
  /// how a chapter for one opening is set up, and its root is what the
  /// outline then prints under its name.
  Future<void> _newChapter() async {
    final into = widget.outline.repertoire;
    final chapter = widget.session.chapter;
    if (into == null) return;
    final wanted = await showNewChapterDialog(
      context,
      fromBoard: chapter == null
          ? null
          : rootMovesFromBoard(chapter, widget.session.cursor),
    );
    if (wanted == null || !mounted) return;
    await announce(
      context,
      widget.library.createChapter(
        into,
        wanted.name,
        rootMoves: wanted.rootMoves,
      ),
      thing: 'chapter',
      name: wanted.name,
      failed: 'Could not create the chapter.',
    );
  }

  Future<void> _rename(OutlineLine line) async {
    final name = await showNameDialog(
      context,
      title: 'Rename line',
      label: 'Line name',
      confirm: 'Rename',
      initial: line.name,
    );
    if (name == null || name == line.name || !mounted) return;
    // The chapter can have been edited while the dialog was up, and a game
    // index names a place in the file rather than a line: renaming by the
    // index alone could put the name on somebody else's line.
    if (widget.outline.nameOf(line.game) != line.name) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That line changed while you were typing; '
            'nothing was renamed.',
          ),
        ),
      );
      return;
    }
    renameLine(widget.session, line.game, name);
  }

  /// Deletes the line and offers the way back, which is the undo the whole
  /// workspace shares: no question first, because the answer is one click
  /// away for as long as the notice is up.
  void _delete(OutlineLine line) {
    deleteLine(widget.session, line.game);
    showDeletionNotice(context, widget.session, 'Deleted 1 line.');
  }

  /// A plain click goes to the line and drops the selection; Ctrl adds or
  /// removes the line; Shift takes every line between the anchor and it.
  void _pick(OutlineLine line) {
    final keys = HardwareKeyboard.instance;
    final toggle = keys.isControlPressed || keys.isMetaPressed;
    setState(() {
      if (keys.isShiftPressed && _anchor != null) {
        _selected = _between(_anchor!, line.game);
      } else if (toggle) {
        if (!_selected.remove(line.game)) _selected.add(line.game);
        _anchor = line.game;
      } else {
        _selected = {};
        _anchor = line.game;
        widget.session.goTo(line.at);
      }
    });
  }

  /// The games of the rows from [a] to [b], in the order the list shows.
  Set<int> _between(int a, int b) {
    final games = [for (final line in widget.outline.lines) line.game];
    final from = games.indexOf(a);
    final to = games.indexOf(b);
    if (from < 0 || to < 0) return {b};
    final (low, high) = from < to ? (from, to) : (to, from);
    return games.sublist(low, high + 1).toSet();
  }

  /// What moves when [line] is dragged or its menu is used: the selection
  /// when the line is in it, else the line alone.
  LineDrag _dragOf(OutlineLine line) {
    final games = _selected.contains(line.game) ? {..._selected} : {line.game};
    return LineDrag(
      games,
      label: games.length == 1 ? line.moves : '${games.length} lines',
    );
  }

  Future<void> _moveTo(OutlineLine line) async {
    final open = widget.session.source;
    final chapters = [
      for (final ref
          in widget.outline.repertoire?.chapters ?? const <ChapterRef>[])
        if (ref != open) ref,
    ];
    final to = await showChoiceDialog<ChapterRef>(
      context,
      title: 'Move to chapter',
      options: chapters,
      label: (ref) => ref.name,
      hint: 'Type a chapter',
      empty: 'This repertoire has no other chapter.',
    );
    if (to == null || !mounted) return;
    await _move(_dragOf(line), to);
  }

  Future<void> _move(LineDrag drag, ChapterRef to, {int? asSidelineOf}) async {
    setState(() => _selected = {});
    final result = await widget.library.moveLines(
      games: drag.games,
      to: to,
      asSidelineOf: asSidelineOf,
    );
    if (!mounted) return;
    await announce(
      context,
      Future.value(result),
      thing: 'line',
      name: drag.label,
      failed: switch (result) {
        LibraryFailure(:final detail) => 'Could not move the lines: $detail',
        _ => 'Could not move the lines.',
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.outline,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            search: _search,
            onSearch: widget.outline.search,
            onCreate: widget.outline.repertoire == null ? null : _newChapter,
          ),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final outline = widget.outline;
    final chapters = outline.chapters;
    if (chapters.isEmpty) {
      return OutlineMessage(
        outline.query.trim().isEmpty
            ? 'No chapters yet\nCreate a chapter, then add your moves.'
            : 'No chapter or line matches "${outline.query}".',
      );
    }
    // A book-sized chapter has thousands of lines, so each row is built when
    // it scrolls into view rather than all of them up front.
    final rows = [
      for (final chapter in chapters) ..._chapterRows(outline, chapter),
    ];
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index](context),
    );
  }

  List<WidgetBuilder> _chapterRows(
    ChapterOutline outline,
    OutlineChapter chapter,
  ) {
    Widget row(BuildContext context) => ChapterRow(
      chapter: chapter,
      onOpen: widget.onOpen,
      // Lines are dragged out of the open chapter, so every other chapter
      // can take them and the open one cannot.
      onDrop: chapter.open ? null : (drag) => _move(drag, chapter.ref),
    );
    if (!chapter.open) return [row];
    final lines = outline.lines;
    return [
      row,
      if (lines.isEmpty)
        (_) => const OutlineMessage('Empty — add lines to fill this chapter.'),
      for (final line in lines) (_) => _lineRow(line, chapter.ref),
    ];
  }

  /// The row follows whether it is [ChapterOutline.currentLine] by itself,
  /// so the cursor going from one line to another redraws those two rows
  /// and not the list.
  Widget _lineRow(OutlineLine line, ChapterRef open) => ValueListenableBuilder(
    valueListenable: widget.outline.isCurrent(line.game),
    builder: (context, current, _) => _lineRowAt(line, open, current: current),
  );

  Widget _lineRowAt(
    OutlineLine line,
    ChapterRef open, {
    required bool current,
  }) => LineRow(
    line: line,
    current: current,
    selected: _selected.contains(line.game),
    drag: _dragOf(line),
    onTap: () => _pick(line),
    onDrop: (drag) => _move(drag, open, asSidelineOf: line.game),
    actions: [
      MenuItemButton(
        onPressed: () => _moveTo(line),
        child: const Text('Move to chapter…'),
      ),
      MenuItemButton(
        onPressed: () => _rename(line),
        child: const Text('Rename line…'),
      ),
      MenuItemButton(
        onPressed: () => _delete(line),
        child: const Text('Delete line'),
      ),
      MenuItemButton(onPressed: _newChapter, child: const Text('New chapter…')),
    ],
  );
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.search,
    required this.onSearch,
    required this.onCreate,
  });

  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Chapters',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              IconButton(
                onPressed: onCreate,
                icon: const Icon(Icons.add, size: IconSize.action),
                tooltip: 'New chapter',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: Space.xs),
          SearchField(
            controller: search,
            hint: 'Find a chapter or line',
            onChanged: onSearch,
          ),
        ],
      ),
    );
  }
}

/// One chapter of the outline. The one on the board is bold and accented, as
/// the old app's is, because it is where every other panel is pointing.
///
/// A chapter that starts after some moves prints them under its name, so a
/// chapter set up for one opening says which. A draft — proposed lines
/// nobody has accepted yet — is muted and says "Proposed".
class ChapterRow extends StatelessWidget {
  const ChapterRow({
    super.key,
    required this.chapter,
    required this.onOpen,
    this.onDrop,
  });

  final OutlineChapter chapter;
  final ValueChanged<ChapterRef> onOpen;

  /// Lines dropped on this chapter become lines of it. Null for a chapter
  /// that cannot take them: the one they are being dragged out of.
  final ValueChanged<LineDrag>? onDrop;

  @override
  Widget build(BuildContext context) {
    final row = _row(context);
    final drop = onDrop;
    if (drop == null) return row;
    return LineDropTarget(accepts: (_) => true, onDrop: drop, child: row);
  }

  Widget _row(BuildContext context) {
    final theme = Theme.of(context);
    final heading = chapter.ref.heading;
    final rooted = !heading.startsAtTheStart;
    return InkWell(
      onTap: () => onOpen(chapter.ref),
      child: SizedBox(
        height: rooted
            ? outlineRowHeight + outlineRootHeight
            : outlineRowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.m),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _nameRow(theme),
              if (rooted)
                Text(
                  heading.rootText,
                  overflow: TextOverflow.ellipsis,
                  style: outlineRootText.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nameRow(ThemeData theme) {
    final draft = chapter.ref.heading.draft;
    return Row(
      children: [
        Expanded(
          child: Text(
            chapter.name,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: chapter.open ? FontWeight.w600 : null,
              color: chapter.open
                  ? theme.colorScheme.primary
                  : draft
                  ? theme.colorScheme.onSurfaceVariant
                  : null,
            ),
          ),
        ),
        if (draft)
          Padding(
            padding: const EdgeInsets.only(left: Space.s),
            child: Text('Proposed', style: theme.textTheme.labelSmall),
          ),
        if (chapter.lines case final lines?)
          Padding(
            padding: const EdgeInsets.only(left: Space.s),
            child: Text(
              lines == 1 ? '1 line' : '$lines lines',
              style: theme.textTheme.labelSmall,
            ),
          ),
      ],
    );
  }
}

/// One line of the open chapter: what it is called, where it starts, and the
/// menu of what can be done to it. It can be picked up and dropped on a
/// chapter or on another line, and other lines can be dropped on it.
class LineRow extends StatelessWidget {
  const LineRow({
    super.key,
    required this.line,
    required this.current,
    required this.selected,
    required this.drag,
    required this.onTap,
    required this.onDrop,
    required this.actions,
  });

  final OutlineLine line;

  /// The cursor is on one of this line's moves.
  final bool current;

  /// Picked with Ctrl or Shift, so it moves with the others picked.
  final bool selected;

  /// What a drag starting on this row carries.
  final LineDrag drag;

  final VoidCallback onTap;

  /// Lines dropped on this one fold into it as variations.
  final ValueChanged<LineDrag> onDrop;

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return LineDropTarget(
      accepts: (dropped) => !dropped.games.contains(line.game),
      onDrop: onDrop,
      child: Draggable<LineDrag>(
        data: drag,
        feedback: LineDragChip(label: drag.label),
        childWhenDragging: Opacity(opacity: 0.4, child: _row(context)),
        child: _row(context),
      ),
    );
  }

  Widget _row(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.2)
          : current
          ? theme.colorScheme.surfaceContainerHighest
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: outlineRowHeight,
          child: Padding(
            padding: const EdgeInsets.only(left: Space.m + outlineIndent),
            child: Row(
              children: [
                if (!line.shared) ...[
                  Flexible(
                    child: Text(line.name, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: Space.s),
                ],
                Expanded(
                  child: Text(
                    line.moves,
                    overflow: TextOverflow.ellipsis,
                    style: monoText.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                RowActions(children: actions),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A sentence where rows would be: nothing here yet, or nothing matching.
class OutlineMessage extends StatelessWidget {
  const OutlineMessage(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Space.m),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

/// What a drag out of the outline carries: which games of the open chapter
/// are on the move. Dropped on a chapter they become lines of their own
/// there; dropped on a line they fold into it as variations.
final class LineDrag {
  const LineDrag(this.games, {required this.label});

  final Set<int> games;

  /// What the chip under the pointer says: the line's moves, or `3 lines`.
  final String label;
}

/// The chip that follows the pointer while lines are dragged.
class LineDragChip extends StatelessWidget {
  const LineDragChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.m,
          vertical: Space.xs,
        ),
        child: Text(
          label,
          style: monoText.copyWith(color: scheme.onSurface),
          maxLines: 1,
        ),
      ),
    );
  }
}

/// A row that takes dragged lines: tinted while they hover over it, and
/// [onDrop] when they land. [accepts] says whether this row can take them
/// at all — a line cannot be dropped on itself, nor a chapter's lines on
/// the chapter they are already in.
class LineDropTarget extends StatelessWidget {
  const LineDropTarget({
    super.key,
    required this.accepts,
    required this.onDrop,
    required this.child,
  });

  final bool Function(LineDrag drag) accepts;
  final ValueChanged<LineDrag> onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<LineDrag>(
      onWillAcceptWithDetails: (details) => accepts(details.data),
      onAcceptWithDetails: (details) => onDrop(details.data),
      builder: (context, candidates, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: candidates.isEmpty
              ? Colors.transparent
              : scheme.primary.withValues(alpha: 0.15),
        ),
        child: child,
      ),
    );
  }
}
