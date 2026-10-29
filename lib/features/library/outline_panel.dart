import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../storage/chapter_files.dart';
import '../../ui/choice_dialog.dart';
import '../../ui/status_bar.dart';
import '../../ui/name_dialog.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import '../../workspace/chapter_commands.dart';
import '../../workspace/document_session.dart';
import 'chapter_outline.dart';
import 'backup_history_dialog.dart';
import 'library.dart';
import 'library_messages.dart';
import 'library_state.dart';
import 'new_chapter_dialog.dart';
import 'outline_rows.dart';
import '../../ui/move_notation.dart';

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

  /// The session's [DocumentSession.arrangement] when [_selected] and
  /// [_anchor] were picked. A game is a place in the file, so once another
  /// chapter is open, or a line is deleted, put back or moved, the picks
  /// would name other lines: they go. A move, a comment or the side changed
  /// leaves every game where it was, and they stay.
  int? _pickedIn;

  void _forgetStalePicks() {
    final arrangement = widget.session.arrangement;
    if (arrangement == _pickedIn) return;
    _pickedIn = arrangement;
    _selected = {};
    _anchor = null;
  }

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
          : rootMovesFromBoard(chapter, widget.session.cursor.value),
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
      StatusScope.of(context)(
        'That line changed while you were typing; nothing was renamed.',
      );
      return;
    }
    renameLine(widget.session, line.game, name);
  }

  /// Deletes the line, with no question first and nothing said after: the
  /// line is gone from the list, and Ctrl+Z puts it back.
  void _delete(OutlineLine line) => deleteLine(widget.session, line.game);

  /// A plain click goes to the line and drops the selection; Ctrl adds or
  /// removes the line; Shift takes every line between the anchor and it.
  void _pick(OutlineLine line) {
    if (!mounted) return;
    final keys = HardwareKeyboard.instance;
    final toggle = keys.isControlPressed || keys.isMetaPressed;
    setState(() {
      _forgetStalePicks();
      if (keys.isShiftPressed && _anchor != null) {
        _selected = _between(_anchor!, line.game);
      } else if (toggle) {
        if (!_selected.remove(line.game)) _selected.add(line.game);
        _anchor = line.game;
      } else {
        _selected = {};
        _anchor = line.game;
        widget.session.cursor.goTo(line.at);
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
    _forgetStalePicks();
    final games = _selected.contains(line.game) ? {..._selected} : {line.game};
    return LineDrag(
      games,
      label: games.length == 1 ? line.moves : '${games.length} lines',
    );
  }

  /// Asks where the lines go: another chapter of the repertoire, or a new
  /// one named here, which is made and takes them in one change.
  Future<void> _moveTo(OutlineLine line) async {
    final open = widget.session.source;
    final into = widget.outline.repertoire;
    final to = await showChoiceDialog<_Destination>(
      context,
      title: 'Move to chapter',
      options: [
        if (into != null) const _NewChapter(),
        for (final ref in into?.chapters ?? const <ChapterRef>[])
          if (ref != open) _Existing(ref),
      ],
      label: (to) => switch (to) {
        _NewChapter() => 'New chapter…',
        _Existing(:final ref) => ref.name,
      },
      hint: 'Type a chapter',
      empty: 'This repertoire has no other chapter.',
    );
    if (to == null || !mounted) return;
    switch (to) {
      case _Existing(:final ref):
        await _move(_dragOf(line), ref);
      case _NewChapter():
        await _moveToNew(_dragOf(line), into!);
    }
  }

  Future<void> _moveToNew(LineDrag drag, RepertoireFolder into) async {
    final name = await showNameDialog(
      context,
      title: 'New chapter',
      label: 'Chapter name',
      confirm: 'Move',
    );
    if (name == null || !mounted) return;
    setState(() => _selected = {});
    await announce(
      context,
      widget.library.moveLinesToNewChapter(
        games: drag.games,
        into: into,
        name: name,
      ),
      thing: 'chapter',
      name: name,
      failed: 'Could not move the lines to a new chapter.',
    );
  }

  Future<void> _move(LineDrag drag, ChapterRef to, {int? asSidelineOf}) async {
    if (!mounted) return;
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

  Future<void> _history() async {
    final history = widget.library.backupHistory;
    final source = widget.session.source;
    if (history == null || source == null) return;
    final text = await showBackupHistory(context, history, source);
    if (text == null || !mounted) return;
    final result = await announce(
      context,
      widget.library.importText(text, name: '${source.name} (restored)'),
      thing: 'repertoire',
      name: source.name,
      failed: 'The archived version could not be restored.',
    );
    if (mounted && result is LibraryAdded) widget.onOpen(result.first);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.outline, widget.library]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            search: _search,
            onSearch: widget.outline.search,
            onCreate: widget.outline.repertoire == null ? null : _newChapter,
            atPosition: widget.outline.atPosition,
            onAtPosition: widget.outline.showAtPosition,
          ),
          if (widget.library.hasPendingLineMove)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: widget.library.busy
                        ? null
                        : () async {
                            final result = await widget.library.retryLineMove();
                            if (!context.mounted) return;
                            await announce(
                              context,
                              Future.value(result),
                              thing: 'line',
                              name: 'Move',
                              failed: 'The line move still needs retrying.',
                            );
                          },
                    child: const Text('Retry line move'),
                  ),
                ),
                TextButton(
                  onPressed: widget.library.busy
                      ? null
                      : () => unawaited(widget.library.discardLineMove()),
                  child: const Text('Discard'),
                ),
              ],
            ),
          Expanded(child: _body(context)),
          if (widget.library.backupHistory != null &&
              widget.session.source != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: widget.library.busy ? null : _history,
                icon: const Icon(Icons.history, size: IconSize.action),
                label: const Text('Version history'),
              ),
            ),
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
      if (outline.searching) (_) => const LinearProgressIndicator(),
      if (outline.searchProblem case final problem?)
        (_) => OutlineMessage(problem),
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
    if (!chapter.open) {
      return [
        row,
        if (outline.query.trim().isNotEmpty)
          for (final line in outline.matchesIn(chapter.ref))
            (_) => ListTile(
              dense: true,
              title: Text(
                displaySan(context, line.moves),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: line.shared
                  ? null
                  : Text(
                      line.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              onTap: () => widget.onOpen(chapter.ref),
            ),
      ];
    }
    final lines = outline.lines;
    return [
      row,
      if (lines.isEmpty)
        (_) => OutlineMessage(
          outline.query.trim().isNotEmpty
              ? 'No lines match this search.'
              : outline.atPosition
              ? 'No line reaches this position.'
              : 'Empty — add lines to fill this chapter.',
        ),
      for (final line in lines) (_) => _lineRow(line, chapter.ref),
    ];
  }

  /// The row follows whether it is [ChapterOutline.isCurrent] by itself,
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
  }) {
    _forgetStalePicks();
    return LineRow(
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
          leadingIcon: const Icon(Icons.edit_outlined, size: IconSize.menu),
          child: const Text('Rename line…'),
        ),
        MenuItemButton(
          onPressed: () => _delete(line),
          leadingIcon: const Icon(Icons.delete_outline, size: IconSize.menu),
          child: const Text('Delete line'),
        ),
        MenuItemButton(
          onPressed: _newChapter,
          child: const Text('New chapter…'),
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.search,
    required this.onSearch,
    required this.onCreate,
    required this.atPosition,
    required this.onAtPosition,
  });

  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final VoidCallback? onCreate;

  /// Whether the lines are narrowed to the board's position.
  final bool atPosition;
  final ValueChanged<bool> onAtPosition;

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
                key: const ValueKey('outline-at-position'),
                onPressed: () => onAtPosition(!atPosition),
                isSelected: atPosition,
                icon: const Icon(
                  Icons.filter_alt_outlined,
                  size: IconSize.action,
                ),
                selectedIcon: const Icon(
                  Icons.filter_alt,
                  size: IconSize.action,
                ),
                tooltip: 'At this position',
                visualDensity: VisualDensity.compact,
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

/// Where Move to chapter sends lines: a chapter already there, or a new one.
sealed class _Destination {
  const _Destination();
}

final class _NewChapter extends _Destination {
  const _NewChapter();
}

final class _Existing extends _Destination {
  const _Existing(this.ref);

  final ChapterRef ref;
}
