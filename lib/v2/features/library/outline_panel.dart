import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../storage/chapter_files.dart';
import '../../ui/choice_dialog.dart';
import '../../ui/name_dialog.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import '../../workspace/chapter_commands.dart';
import '../../workspace/document_session.dart';
import '../../workspace/undo_notice.dart';
import 'chapter_outline.dart';
import 'library.dart';
import 'library_messages.dart';
import 'line_drag.dart';
import 'new_chapter_dialog.dart';
import 'outline_rows.dart';

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
    return ListView(
      children: [
        for (final chapter in chapters) ..._chapterRows(outline, chapter),
      ],
    );
  }

  List<Widget> _chapterRows(ChapterOutline outline, OutlineChapter chapter) {
    final row = ChapterRow(
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
        const OutlineMessage('Empty — add lines to fill this chapter.'),
      for (final line in lines) _lineRow(line, chapter.ref),
    ];
  }

  Widget _lineRow(OutlineLine line, ChapterRef open) => LineRow(
    line: line,
    current: line.game == widget.outline.currentLine,
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
