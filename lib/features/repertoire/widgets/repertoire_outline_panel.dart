/// The outline panel: the repertoire as chapters and lines, first-class.
///
/// This is the left column of the builder and the answer to "what is in this
/// repertoire?" — every folder, chapter and line, in one tree, always
/// visible. It reads like a file browser because it is one: folders nest,
/// chapters are files, lines are the games inside. Everything is reachable
/// two ways — a right-click (or long-press) menu, and drag & drop — and every
/// edit goes through [RepertoireOutlineController], which edits the disk and
/// rebuilds, so the tree never shows a state the folder does not have.
///
/// Drag & drop, in full:
///
///  * A line dropped **between** two lines lands there — in another chapter
///    or, to reorder, in its own. Dropped on a chapter's row it goes to the
///    end of that chapter.
///  * Ctrl/Cmd-click and Shift-click pick several lines of one chapter; a
///    drag of any picked line carries them all, and the context menu acts
///    on all of them.
///  * Lines dropped on a **folder** (or the drop zone at the foot of the
///    list, for the top level) start a new chapter there.
///  * Chapters and folders drop into folders, or into the foot zone for the
///    top level. A collapsed folder or chapter opens after the pointer rests
///    on it, and the list scrolls when a drag nears its edge.
///  * With a mouse a drag starts at once; on touch it starts after a press.
///
/// Every move and deletion is reported in a toast with Undo.
///
/// The panel does not know about the board. It reports what the user picked
/// ([onOpenChapter], [onOpenLine]) and what they asked for
/// ([onGenerateInto], [onAuditChapter], [onTrainChapter]) and lets the screen
/// act.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:path/path.dart' as p;

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/app_messages.dart';
import '../../../widgets/common/confirm_dialog.dart';
import '../../../widgets/common/name_entry_dialog.dart';
import '../controllers/repertoire_outline_controller.dart';
import '../models/outline_rows.dart';
import '../models/repertoire_outline.dart';
import '../services/repertoire_outline_service.dart';

/// Payload of a drag from the outline: a line, chapter or folder.
///
/// A dragged line that is part of a multi-selection carries the whole
/// selection in [lineIndexes]; they all live in [node]'s chapter.
class OutlineDragData {
  final OutlineNode node;
  final Set<int> lineIndexes;

  const OutlineDragData(this.node, {this.lineIndexes = const {}});

  OutlineLine? get line => node is OutlineLine ? node as OutlineLine : null;

  /// The game indexes moving, for a line drag; empty otherwise.
  Set<int> get indexes {
    final l = line;
    if (l == null) return const {};
    return lineIndexes.isEmpty ? {l.gameIndex} : lineIndexes;
  }

  int get lineCount => indexes.length;
}

class RepertoireOutlinePanel extends StatefulWidget {
  const RepertoireOutlinePanel({
    super.key,
    required this.controller,
    required this.onOpenChapter,
    required this.onOpenLine,
    this.currentMoves = const [],
    this.selectedLine,
    this.onGenerateInto,
    this.onAuditChapter,
    this.onTrainChapter,
    this.onTrainLine,
    this.onShowMetrics,
    this.onCollapse,
    this.onPlanBuild,
    this.chapterBadge,
    this.title,
  });

  final RepertoireOutlineController controller;

  /// Load this chapter into the board/editor.
  final ValueChanged<String> onOpenChapter;

  /// Load this line (its chapter first, if it is not the active one).
  final void Function(String chapterPath, OutlineLine line) onOpenLine;

  /// The SAN sequence on the board — used by the "at this position" filter.
  final List<String> currentMoves;

  /// The line the editor is on, if any: `(chapterPath, gameIndex)`.
  final ({String chapterPath, int gameIndex})? selectedLine;

  /// Open the generation setup with this chapter as the target.
  final ValueChanged<String>? onGenerateInto;
  final ValueChanged<String>? onAuditChapter;
  final ValueChanged<String>? onTrainChapter;
  final void Function(String chapterPath, OutlineLine line)? onTrainLine;

  /// Swap to the metrics view (coverage, ease…) of the lines list.
  final VoidCallback? onShowMetrics;

  /// Collapse the column to a strip (wide layout only; null hides the button).
  final VoidCallback? onCollapse;

  /// Open the planner (offered in the empty state next to "New chapter").
  final VoidCallback? onPlanBuild;

  /// A short status to show after a chapter's name ("building…", "queued"),
  /// or null for none.
  final String? Function(String chapterPath)? chapterBadge;

  /// Overrides the root folder's name in the header.
  final String? title;

  @override
  State<RepertoireOutlinePanel> createState() => _RepertoireOutlinePanelState();
}

class _RepertoireOutlinePanelState extends State<RepertoireOutlinePanel> {
  final _searchController = TextEditingController();
  final _scroll = ScrollController();
  final _listKey = GlobalKey();
  String _search = '';
  bool _atPosition = false;
  Timer? _debounce;

  /// Lines picked with Ctrl/Shift-click, all in [_selectionChapter].
  /// Cleared whenever the outline is rebuilt: an edit re-indexes lines.
  final Set<int> _selection = {};
  String? _selectionChapter;
  int? _anchor;
  OutlineFolder? _selectionOutline;

  /// The drag in progress, if any: the foot drop zone shows for it.
  OutlineDragData? _dragging;
  Timer? _autoScroll;
  double _autoScrollStep = 0;

  RepertoireOutlineController get _c => widget.controller;

  @override
  void dispose() {
    _debounce?.cancel();
    _autoScroll?.cancel();
    _searchController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _search = value.trim().toLowerCase());
    });
  }

  /// Drop both filters.
  ///
  /// Cancelling the debounce is the point: a timer still in flight from an
  /// earlier keystroke would fire after the clear and restore the text the
  /// user just removed, leaving the field empty but the list still filtered.
  void _clearFilters() {
    _debounce?.cancel();
    _searchController.clear();
    setState(() {
      _search = '';
      _atPosition = false;
    });
  }

  OutlineFilter get _filter => OutlineFilter(
    search: _search,
    atPosition: _atPosition,
    currentMoves: widget.currentMoves,
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final outline = _c.outline;
        if (!identical(outline, _selectionOutline)) {
          _selectionOutline = outline;
          _selection.clear();
          _selectionChapter = null;
          _anchor = null;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              title: widget.title ?? outline?.name ?? 'Repertoire',
              lineCount: outline?.lineCount ?? 0,
              chapterCount: outline == null ? 0 : outline.chapterList.length,
              loading: _c.isLoading,
              onNewChapter: outline == null
                  ? null
                  : () => _promptCreateChapter(outline.path),
              onShowMetrics: widget.onShowMetrics,
              onCollapse: widget.onCollapse,
            ),
            _FilterRow(
              controller: _searchController,
              onChanged: _onSearchChanged,
              atPosition: _atPosition,
              atPositionEnabled: widget.currentMoves.isNotEmpty,
              onAtPositionChanged: (v) => setState(() => _atPosition = v),
            ),
            const Divider(height: 1),
            Expanded(child: _buildBody(outline)),
          ],
        );
      },
    );
  }

  Widget _buildBody(OutlineFolder? outline) {
    if (_c.error != null) {
      return _Empty(
        icon: Icons.error_outline,
        title: 'Could not read this repertoire',
        detail: _c.error!,
        action: TextButton(onPressed: _c.refresh, child: const Text('Retry')),
      );
    }
    if (outline == null) {
      return _c.isLoading
          ? const Center(child: CircularProgressIndicator())
          : const _Empty(
              icon: Icons.folder_open,
              title: 'No repertoire open',
              detail: 'Pick or create one from the title above.',
            );
    }
    if (outline.children.isEmpty) {
      return _Empty(
        icon: Icons.menu_book_outlined,
        title: 'No chapters yet',
        detail:
            'A repertoire is chapters, and chapters hold lines. Make a '
            'chapter, then fill it from the Actions menu.',
        action: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            if (widget.onPlanBuild != null)
              FilledButton(
                onPressed: widget.onPlanBuild,
                child: const Text('Plan the lines'),
              ),
            FilledButton.tonalIcon(
              onPressed: () => _promptCreateChapter(outline.path),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New chapter'),
            ),
          ],
        ),
      );
    }

    final filter = _filter;
    final rows = _c.rows(filter);
    if (rows.isEmpty) {
      return _Empty(
        icon: Icons.search_off,
        title: 'Nothing matches',
        detail: _atPosition
            ? 'No line passes through this position.'
            : 'No chapter or line matches "$_search".',
        action: TextButton(
          onPressed: _clearFilters,
          child: const Text('Clear filters'),
        ),
      );
    }
    // Rows are flattened by the controller once per change and rendered
    // lazily here: a fixed extent lets the list size itself without
    // building a single row, and stable keys keep row state (drag, hover)
    // attached across rebuilds.  A drag adds one row at the foot: the drop
    // zone for the top level.
    final foot = _footZoneFor(_dragging, outline);
    return GestureDetector(
      key: _listKey,
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (d) => _backgroundMenu(d.globalPosition, outline),
      child: ListView.builder(
        controller: _scroll,
        primary: false,
        padding: const EdgeInsets.only(bottom: 24),
        itemExtent: OutlineRow.height,
        itemCount: rows.length + (foot == null ? 0 : 1),
        itemBuilder: (context, index) =>
            index < rows.length ? _buildRow(rows[index]) : foot!,
      ),
    );
  }

  // ── Tree rows ──────────────────────────────────────────────────────────

  Widget _buildRow(OutlineRow row) {
    switch (row) {
      case FolderRow(:final folder, :final depth, :final expanded):
        return _DropTarget(
          key: ValueKey(row.key),
          accepts: (d) => _canDropOnFolder(d, folder),
          onDrop: (d, _) => _dropOnFolder(d, folder),
          onLinger: expanded ? null : () => _c.toggleFolder(folder.path),
          child: _FolderRow(
            folder: folder,
            depth: depth,
            expanded: expanded,
            onToggle: () => _c.toggleFolder(folder.path),
            onContextMenu: (pos) => _folderMenu(pos, folder),
            drag: _dragHooks,
          ),
        );
      case ChapterRow(
        :final chapter,
        :final depth,
        :final active,
        :final open,
        :final visibleLines,
      ):
        return _DropTarget(
          key: ValueKey(row.key),
          accepts: (d) => _canDropOnChapter(d, chapter),
          onDrop: (d, _) => _dropOnChapter(d, chapter),
          onLinger: open ? null : () => _c.setChapterOpen(chapter.path, true),
          child: _ChapterRow(
            chapter: chapter,
            depth: depth,
            active: active,
            open: open,
            badge: widget.chapterBadge?.call(chapter.path),
            visibleLines: visibleLines,
            onTap: () {
              if (!active) widget.onOpenChapter(chapter.path);
              _c.setChapterOpen(chapter.path, true);
            },
            onToggle: () => _c.toggleChapter(chapter.path),
            onContextMenu: (pos) => _chapterMenu(pos, chapter),
            drag: _dragHooks,
          ),
        );
      case SectionRow(:final title, :final depth, :final count):
        return _SectionRow(
          key: ValueKey(row.key),
          title: title ?? 'Other lines',
          depth: depth,
          count: count,
        );
      case LineRow(:final chapter, :final line, :final depth):
        final sel = widget.selectedLine;
        final selected =
            sel != null &&
            sel.gameIndex == line.gameIndex &&
            p.equals(sel.chapterPath, chapter.path);
        final picked = _isPicked(chapter, line);
        return _DropTarget(
          key: ValueKey(row.key),
          accepts: (d) => _canDropOnLine(d, chapter, line),
          onDrop: (d, place) => _dropOnLine(d, chapter, line, place),
          insertion: true,
          child: _LineRow(
            line: line,
            depth: depth,
            selected: selected || picked,
            onTap: () => _tapLine(chapter, line),
            onContextMenu: (pos) => _lineMenu(pos, chapter, line),
            dragData: _dragDataFor(chapter, line),
            drag: _dragHooks,
          ),
        );
      case HintRow(:final depth, :final text):
        return _Hint(key: ValueKey(row.key), depth: depth, text: text);
    }
  }

  // ── Selection ──────────────────────────────────────────────────────────

  bool _isPicked(OutlineChapter chapter, OutlineLine line) =>
      _selectionChapter != null &&
      p.equals(_selectionChapter!, chapter.path) &&
      _selection.contains(line.gameIndex);

  /// Plain click opens the line. Ctrl/Cmd-click toggles it in the
  /// selection, Shift-click extends the selection from the last click (or
  /// the line on the board) to it. The selection lives in one chapter:
  /// picking in another starts over there.
  void _tapLine(OutlineChapter chapter, OutlineLine line) {
    final keys = HardwareKeyboard.instance;
    final toggle = keys.isControlPressed || keys.isMetaPressed;
    final extend = keys.isShiftPressed;
    if (!toggle && !extend) {
      if (_selection.isNotEmpty) {
        setState(() {
          _selection.clear();
          _selectionChapter = null;
        });
      }
      _anchor = line.gameIndex;
      widget.onOpenLine(chapter.path, line);
      return;
    }
    setState(() {
      if (_selectionChapter == null ||
          !p.equals(_selectionChapter!, chapter.path)) {
        _selection.clear();
        _selectionChapter = chapter.path;
        _anchor = null;
      }
      if (toggle) {
        if (!_selection.remove(line.gameIndex)) {
          _selection.add(line.gameIndex);
        }
        _anchor = line.gameIndex;
        return;
      }
      final board = widget.selectedLine;
      final from =
          _anchor ??
          (board != null && p.equals(board.chapterPath, chapter.path)
              ? board.gameIndex
              : line.gameIndex);
      final lo = from < line.gameIndex ? from : line.gameIndex;
      final hi = from < line.gameIndex ? line.gameIndex : from;
      for (final l in chapter.lines ?? const <OutlineLine>[]) {
        if (l.gameIndex >= lo && l.gameIndex <= hi) {
          _selection.add(l.gameIndex);
        }
      }
      _anchor ??= from;
    });
  }

  /// What a drag of [line] carries: every picked line when it is one of
  /// them, else itself.
  OutlineDragData _dragDataFor(OutlineChapter chapter, OutlineLine line) =>
      OutlineDragData(
        line,
        lineIndexes: _isPicked(chapter, line) ? {..._selection} : const {},
      );

  /// The lines a menu on [line] acts on: the selection when it is in it.
  Set<int> _targetsFor(OutlineChapter chapter, OutlineLine line) =>
      _isPicked(chapter, line) ? {..._selection} : {line.gameIndex};

  // ── Drag & drop rules ──────────────────────────────────────────────────

  _DragHooks get _dragHooks => _DragHooks(
    onStarted: (d) => setState(() => _dragging = d),
    onUpdate: _onDragMoved,
    onEnded: () {
      _stopAutoScroll();
      if (mounted) setState(() => _dragging = null);
    },
  );

  bool _canDropOnFolder(OutlineDragData d, OutlineFolder target) {
    switch (d.node) {
      case OutlineFolder f:
        return !f.contains(target.path) &&
            !p.equals(p.dirname(f.path), target.path);
      case OutlineChapter c:
        return !p.equals(p.dirname(c.path), target.path);
      case OutlineLine _:
        return true;
    }
  }

  bool _canDropOnChapter(OutlineDragData d, OutlineChapter target) {
    final line = d.line;
    return line != null && !p.equals(line.path, target.path);
  }

  /// A line can land before or after any line but one of those moving.
  bool _canDropOnLine(
    OutlineDragData d,
    OutlineChapter chapter,
    OutlineLine target,
  ) {
    final line = d.line;
    if (line == null) return false;
    return !(p.equals(line.path, chapter.path) &&
        d.indexes.contains(target.gameIndex));
  }

  Future<void> _dropOnFolder(OutlineDragData d, OutlineFolder target) async {
    switch (d.node) {
      case OutlineFolder f:
        _report(await _c.moveFolder(f.path, target.path));
      case OutlineChapter c:
        _report(await _c.moveChapter(c.path, target.path));
      case OutlineLine _:
        await _promptNewChapterFromLines(target.path, d);
    }
  }

  Future<void> _dropOnChapter(OutlineDragData d, OutlineChapter target) async {
    _report(
      await _c.moveLines(
        fromChapterPath: d.line!.path,
        gameIndexes: d.indexes,
        toChapterPath: target.path,
      ),
    );
  }

  Future<void> _dropOnLine(
    OutlineDragData d,
    OutlineChapter chapter,
    OutlineLine target,
    _DropPlace place,
  ) async {
    _report(
      await _c.moveLines(
        fromChapterPath: d.line!.path,
        gameIndexes: d.indexes,
        toChapterPath: chapter.path,
        toIndex: place == _DropPlace.before
            ? target.gameIndex
            : target.gameIndex + 1,
      ),
    );
  }

  /// The drop zone at the foot of the list while [d] is being dragged:
  /// the top level, for anything not already there. Null hides it.
  Widget? _footZoneFor(OutlineDragData? d, OutlineFolder root) {
    if (d == null) return null;
    final String label;
    switch (d.node) {
      case OutlineLine _:
        label = d.lineCount == 1
            ? 'New chapter at the top level'
            : 'New chapter from ${d.lineCount} lines at the top level';
      case OutlineChapter c:
        if (p.equals(p.dirname(c.path), root.path)) return null;
        label = 'Move to the top level';
      case OutlineFolder f:
        if (p.equals(p.dirname(f.path), root.path)) return null;
        label = 'Move to the top level';
    }
    return _DropTarget(
      key: const ValueKey('foot-drop-zone'),
      accepts: (_) => true,
      onDrop: (d, _) async {
        switch (d.node) {
          case OutlineLine _:
            await _promptNewChapterFromLines(root.path, d);
          case OutlineChapter c:
            _report(await _c.moveChapter(c.path, root.path));
          case OutlineFolder f:
            _report(await _c.moveFolder(f.path, root.path));
        }
      },
      child: _FootZone(label: label),
    );
  }

  // ── Auto-scroll while dragging near an edge ────────────────────────────

  static const _edge = 40.0;

  void _onDragMoved(Offset global) {
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final y = box.globalToLocal(global).dy;
    final h = box.size.height;
    double v = 0;
    if (y < _edge) {
      v = -(_edge - y) / _edge;
    } else if (y > h - _edge) {
      v = (y - (h - _edge)) / _edge;
    }
    _autoScrollStep = v.clamp(-1.0, 1.0) * 14;
    if (_autoScrollStep == 0) {
      _stopAutoScroll();
    } else {
      _autoScroll ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _autoScrollTick(),
      );
    }
  }

  void _autoScrollTick() {
    if (!_scroll.hasClients) return _stopAutoScroll();
    final pos = _scroll.position;
    final next = (pos.pixels + _autoScrollStep).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (next == pos.pixels) return;
    _scroll.jumpTo(next);
  }

  void _stopAutoScroll() {
    _autoScroll?.cancel();
    _autoScroll = null;
    _autoScrollStep = 0;
  }

  // ── Context menus ──────────────────────────────────────────────────────

  Future<void> _backgroundMenu(Offset pos, OutlineFolder root) async {
    final action = await _showMenu(pos, [
      const _MenuEntry('new_chapter', 'New chapter…', Icons.note_add_outlined),
      const _MenuEntry(
        'new_folder',
        'New folder…',
        Icons.create_new_folder_outlined,
      ),
    ]);
    switch (action) {
      case 'new_chapter':
        await _promptCreateChapter(root.path);
      case 'new_folder':
        await _promptCreateFolder(root.path);
    }
  }

  Future<void> _folderMenu(Offset pos, OutlineFolder folder) async {
    final action = await _showMenu(pos, [
      const _MenuEntry(
        'new_chapter',
        'New chapter here…',
        Icons.note_add_outlined,
      ),
      const _MenuEntry(
        'new_folder',
        'New folder here…',
        Icons.create_new_folder_outlined,
      ),
      const _MenuEntry.divider(),
      const _MenuEntry('rename', 'Rename…', Icons.drive_file_rename_outline),
      const _MenuEntry('move', 'Move to…', Icons.drive_file_move_outline),
      const _MenuEntry.divider(),
      const _MenuEntry(
        'delete',
        'Delete folder…',
        Icons.delete_outline,
        danger: true,
      ),
    ]);
    switch (action) {
      case 'new_chapter':
        await _promptCreateChapter(folder.path);
      case 'new_folder':
        await _promptCreateFolder(folder.path);
      case 'rename':
        final name = await _promptName(
          title: 'Rename folder',
          rename: true,
          fieldLabel: 'Folder name',
          confirmLabel: 'Rename',
          initial: folder.name,
          taken: _siblingFolderNames(folder.path),
        );
        if (name != null) _report(await _c.renameFolder(folder.path, name));
      case 'move':
        final target = await _pickFolder(
          exclude: (f) =>
              folder.contains(f.path) ||
              p.equals(f.path, p.dirname(folder.path)),
        );
        if (target != null) {
          _report(await _c.moveFolder(folder.path, target.path));
        }
      case 'delete':
        if (!mounted) return;
        if (await confirmAction(
          context,
          title: 'Delete folder "${folder.name}"?',
          message:
              '${folder.allChapters.length} chapter(s) and ${folder.lineCount} '
              'line(s) inside it will be moved to Chess Auto Prep recovery '
              'trash.',
          confirmLabel: 'Delete',
        )) {
          _report(await _c.deleteFolder(folder.path));
        }
    }
  }

  Future<void> _chapterMenu(Offset pos, OutlineChapter chapter) async {
    final action = await _showMenu(pos, [
      const _MenuEntry('open', 'Open', Icons.launch),
      if (widget.onGenerateInto != null)
        const _MenuEntry(
          'generate',
          'Generate lines into this chapter…',
          Icons.auto_awesome,
        ),
      if (widget.onAuditChapter != null)
        const _MenuEntry('audit', 'Audit this chapter', Icons.policy_outlined),
      if (widget.onTrainChapter != null)
        const _MenuEntry('train', 'Train this chapter', Icons.school_outlined),
      const _MenuEntry.divider(),
      const _MenuEntry('rename', 'Rename…', Icons.drive_file_rename_outline),
      const _MenuEntry(
        'move',
        'Move to folder…',
        Icons.drive_file_move_outline,
      ),
      const _MenuEntry(
        'new_sibling',
        'New chapter next to this…',
        Icons.note_add_outlined,
      ),
      // Only an imported course has course chapters sitting inside one file.
      if (_courseChaptersIn(chapter).length >= 2)
        const _MenuEntry(
          'split',
          'Split into chapters…',
          Icons.call_split_outlined,
        ),
      const _MenuEntry.divider(),
      const _MenuEntry(
        'delete',
        'Delete chapter…',
        Icons.delete_outline,
        danger: true,
      ),
    ]);
    switch (action) {
      case 'open':
        widget.onOpenChapter(chapter.path);
      case 'generate':
        widget.onGenerateInto?.call(chapter.path);
      case 'audit':
        widget.onAuditChapter?.call(chapter.path);
      case 'train':
        widget.onTrainChapter?.call(chapter.path);
      case 'rename':
        final name = await _promptName(
          title: 'Rename chapter',
          rename: true,
          fieldLabel: 'Chapter name',
          confirmLabel: 'Rename',
          initial: chapter.name,
          taken: _chapterNamesIn(p.dirname(chapter.path)),
        );
        if (name != null) _report(await _c.renameChapter(chapter.path, name));
      case 'move':
        final target = await _pickFolder(
          exclude: (f) => p.equals(f.path, p.dirname(chapter.path)),
        );
        if (target != null) {
          _report(await _c.moveChapter(chapter.path, target.path));
        }
      case 'new_sibling':
        await _promptCreateChapter(p.dirname(chapter.path));
      case 'split':
        await _promptSplitChapter(chapter);
      case 'delete':
        if (!mounted) return;
        if (await confirmAction(
          context,
          title: 'Delete chapter "${chapter.name}"?',
          message:
              '${chapter.lineCount} line(s) will be moved to Chess Auto Prep '
              'recovery trash.',
          confirmLabel: 'Delete',
        )) {
          _report(await _c.deleteChapter(chapter.path));
        }
    }
  }

  Future<void> _lineMenu(
    Offset pos,
    OutlineChapter chapter,
    OutlineLine line,
  ) async {
    final targets = _targetsFor(chapter, line);
    final n = targets.length;
    final many = n > 1;
    final what = many ? '$n lines' : 'line';
    final action = await _showMenu(pos, [
      if (!many) const _MenuEntry('open', 'Load on the board', Icons.launch),
      if (!many && widget.onTrainLine != null)
        const _MenuEntry('train', 'Train this line', Icons.school_outlined),
      if (!many) const _MenuEntry.divider(),
      if (!many)
        const _MenuEntry('rename', 'Rename…', Icons.drive_file_rename_outline),
      _MenuEntry(
        'move',
        'Move $what to chapter…',
        Icons.drive_file_move_outline,
      ),
      _MenuEntry(
        'new_chapter',
        'Move $what to a new chapter…',
        Icons.note_add_outlined,
      ),
      const _MenuEntry.divider(),
      _MenuEntry('delete', 'Delete $what', Icons.delete_outline, danger: true),
    ]);
    switch (action) {
      case 'open':
        widget.onOpenLine(chapter.path, line);
      case 'train':
        widget.onTrainLine?.call(chapter.path, line);
      case 'rename':
        final name = await _promptName(
          title: 'Rename line',
          rename: true,
          fieldLabel: 'Line name',
          confirmLabel: 'Rename',
          initial: line.name,
          validateFileName: false,
        );
        if (name != null) {
          _report(await _c.renameLine(chapter.path, line.gameIndex, name));
        }
      case 'move':
        final target = await _pickChapter(exclude: chapter.path);
        if (target != null) {
          _report(
            await _c.moveLines(
              fromChapterPath: chapter.path,
              gameIndexes: targets,
              toChapterPath: target.path,
            ),
          );
        }
      case 'new_chapter':
        await _promptNewChapterFromLines(
          p.dirname(chapter.path),
          OutlineDragData(line, lineIndexes: targets),
        );
      case 'delete':
        // No "are you sure?": the toast offers Undo instead.
        _report(await _c.deleteLines(chapter.path, targets));
    }
  }

  Future<String?> _showMenu(Offset pos, List<_MenuEntry> entries) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        pos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final e in entries)
          if (e.isDivider)
            const PopupMenuDivider(height: 8)
          else
            PopupMenuItem<String>(
              value: e.id,
              height: 34,
              child: Row(
                children: [
                  Icon(
                    e.icon,
                    size: 16,
                    color: e.danger
                        ? AppColors.danger
                        : AppColors.onSurfaceMuted,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      e.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: e.danger ? AppColors.danger : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  // ── Dialogs ────────────────────────────────────────────────────────────

  /// Chapter titles a course export carries inside [chapter]'s single file —
  /// the sections the outline already shows under it. Empty for a hand-made
  /// chapter, which is what keeps "Split into chapters…" out of its menu.
  List<String> _courseChaptersIn(OutlineChapter chapter) =>
      chapter.sections.whereType<String>().toList();

  Future<void> _promptSplitChapter(OutlineChapter chapter) async {
    final titles = _courseChaptersIn(chapter);
    final staying = chapter.linesIn(null).length;
    final moving = chapter.lineCount - staying;
    if (!await confirmAction(
      context,
      title: 'Split "${chapter.name}" into ${titles.length} chapters?',
      message:
          '$moving line(s) move into new chapter files named after the course\'s '
          'own chapters, and their training progress moves with them.\n\n'
          '${staying == 0 ? '"${chapter.name}" is left empty and removed.' : '$staying untitled line(s) stay in "${chapter.name}".'}',
      confirmLabel: 'Split',
      destructive: false,
    )) {
      return;
    }
    _report(await _c.splitChapter(chapter.path));
  }

  Future<void> _promptCreateChapter(String folderPath) async {
    final name = await _promptName(
      title: 'New chapter',
      fieldLabel: 'Chapter name',
      confirmLabel: 'Create',
      taken: _chapterNamesIn(folderPath),
    );
    if (name == null) return;
    _report(await _c.createChapter(folderPath: folderPath, name: name));
    if (!mounted) return;
    _openCreated(folderPath, name);
  }

  /// A new chapter in [folderPath] out of the lines [d] carries — what a
  /// drop on a folder, the foot zone, or "Move to a new chapter…" does.
  /// The name field starts as the first line's name, which is usually the
  /// variation the chapter is about.
  Future<void> _promptNewChapterFromLines(
    String folderPath,
    OutlineDragData d,
  ) async {
    final line = d.line!;
    final n = d.lineCount;
    final name = await _promptName(
      title: n == 1 ? 'New chapter for this line' : 'New chapter for $n lines',
      fieldLabel: 'Chapter name',
      confirmLabel: 'Create',
      initial: line.name,
      taken: _chapterNamesIn(folderPath),
    );
    if (name == null) return;
    _report(
      await _c.createChapterWithLines(
        folderPath: folderPath,
        name: name,
        fromChapterPath: line.path,
        gameIndexes: d.indexes,
      ),
    );
    if (!mounted) return;
    _openCreated(folderPath, name);
  }

  /// A brand-new chapter is what the user wants to work in next.
  void _openCreated(String folderPath, String name) {
    final created = _c.outline?.findChapter(p.join(folderPath, '$name.pgn'));
    if (created != null) widget.onOpenChapter(created.path);
  }

  Future<void> _promptCreateFolder(String parentPath) async {
    final name = await _promptName(
      title: 'New folder',
      fieldLabel: 'Folder name',
      confirmLabel: 'Create',
      taken: _folderNamesIn(parentPath),
    );
    if (name == null) return;
    _report(await _c.createFolder(parentPath: parentPath, name: name));
  }

  /// One name prompt for everything here. A file-system name is checked as
  /// one, and a name already used beside it is refused in the field rather
  /// than by a toast after the dialog has gone.
  Future<String?> _promptName({
    required String title,
    required String fieldLabel,
    required String confirmLabel,
    String initial = '',
    Set<String> taken = const {},
    bool validateFileName = true,
    bool rename = false,
  }) {
    final own = initial.toLowerCase();
    return showNameEntryDialog(
      context,
      title: title,
      fieldLabel: fieldLabel,
      confirmLabel: confirmLabel,
      initialValue: initial,
      // A rename left as it was is a cancel; a suggested name kept as it
      // is, for a new chapter, is an answer.
      allowUnchanged: !rename,
      validate: (name) {
        if (validateFileName) {
          final problem = RepertoireOutlineService.validateName(name);
          if (problem != null) return problem;
        }
        final lower = name.trim().toLowerCase();
        if (lower != own && taken.contains(lower)) {
          return 'A ${fieldLabel.split(' ').first.toLowerCase()} named '
              '"${name.trim()}" already exists here.';
        }
        return null;
      },
    );
  }

  Set<String> _chapterNamesIn(String folderPath) => {
    for (final c
        in _c.outline?.findFolder(folderPath)?.chapters ??
            const <OutlineChapter>[])
      c.name.toLowerCase(),
  };

  Set<String> _folderNamesIn(String parentPath) => {
    for (final f
        in _c.outline?.findFolder(parentPath)?.folders ??
            const <OutlineFolder>[])
      f.name.toLowerCase(),
  };

  Set<String> _siblingFolderNames(String folderPath) =>
      _folderNamesIn(p.dirname(folderPath));

  Future<OutlineFolder?> _pickFolder({
    required bool Function(OutlineFolder) exclude,
  }) {
    final root = _c.outline;
    if (root == null) return Future.value();
    final options = [
      root,
      ...root.allFolders,
    ].where((f) => !exclude(f)).toList();
    return showDialog<OutlineFolder>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Move to folder'),
        children: [
          if (options.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No other folder to move into.'),
            ),
          for (final f in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(f),
              child: Row(
                children: [
                  const Icon(Icons.folder_outlined, size: 18),
                  const SizedBox(width: 10),
                  Text(
                    p.equals(f.path, root.path)
                        ? '${f.name} (top level)'
                        : p.relative(f.path, from: root.path),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<OutlineChapter?> _pickChapter({required String exclude}) {
    final root = _c.outline;
    if (root == null) return Future.value();
    final options = root.allChapters
        .where((c) => !p.equals(c.path, exclude))
        .toList();
    return showDialog<OutlineChapter>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Move to chapter'),
        children: [
          if (options.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No other chapter to move into.'),
            ),
          for (final c in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(c),
              child: Row(
                children: [
                  const Icon(Icons.article_outlined, size: 18),
                  const SizedBox(width: 10),
                  Text(p.withoutExtension(p.relative(c.path, from: root.path))),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// A refusal is an error toast; a move or deletion is a toast with Undo.
  void _report(OutlineEditOutcome outcome) {
    if (!mounted) return;
    if (!outcome.ok) {
      showAppSnackBar(context, outcome.error!, isError: true);
      return;
    }
    final message = outcome.message;
    if (message == null) return;
    final undo = outcome.undo;
    showAppSnackBar(
      context,
      message,
      actionLabel: undo == null ? null : 'Undo',
      onAction: undo == null ? null : () async => _report(await undo()),
      duration: undo == null ? null : const Duration(seconds: 8),
    );
  }
}

// ── Pieces ─────────────────────────────────────────────────────────────────

class _MenuEntry {
  final String id;
  final String label;
  final IconData? icon;
  final bool danger;
  final bool isDivider;
  const _MenuEntry(this.id, this.label, this.icon, {this.danger = false})
    : isDivider = false;
  const _MenuEntry.divider()
    : id = '',
      label = '',
      icon = null,
      danger = false,
      isDivider = true;
}

class _Header extends StatelessWidget {
  final String title;
  final int chapterCount;
  final int lineCount;
  final bool loading;
  final VoidCallback? onNewChapter;
  final VoidCallback? onShowMetrics;
  final VoidCallback? onCollapse;

  const _Header({
    required this.title,
    required this.chapterCount,
    required this.lineCount,
    required this.loading,
    required this.onNewChapter,
    required this.onShowMetrics,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  loading
                      ? 'Reading…'
                      : '$chapterCount chapter${chapterCount == 1 ? '' : 's'} · '
                            '$lineCount line${lineCount == 1 ? '' : 's'}',
                  style: AppTextStyles.caption,
                ),
              ],
            ),
          ),
          if (onShowMetrics != null)
            IconButton(
              tooltip: 'Line metrics (coverage, ease…)',
              icon: const Icon(Icons.insights_outlined, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: onShowMetrics,
            ),
          if (onCollapse != null)
            IconButton(
              tooltip: 'Hide chapters (L)',
              icon: const Icon(Icons.keyboard_double_arrow_left, size: 16),
              visualDensity: VisualDensity.compact,
              onPressed: onCollapse,
            ),
          // One click, one chapter. Folders are the rarer thing, so they
          // live in the right-click menus (on a folder, or on empty space).
          IconButton(
            tooltip: 'New chapter',
            icon: const Icon(Icons.add, size: 20),
            visualDensity: VisualDensity.compact,
            onPressed: onNewChapter,
          ),
        ],
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool atPosition;
  final bool atPositionEnabled;
  final ValueChanged<bool> onAtPositionChanged;

  const _FilterRow({
    required this.controller,
    required this.onChanged,
    required this.atPosition,
    required this.atPositionEnabled,
    required this.onAtPositionChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 30,
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  prefixIcon: const Icon(Icons.search, size: 16),
                  prefixIconConstraints: const BoxConstraints(minWidth: 28),
                  hintText: 'Find a chapter or line',
                  hintStyle: const TextStyle(fontSize: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: atPositionEnabled
                ? 'Only lines that reach the position on the board'
                : 'Play a move on the board to filter by position',
            child: FilterChip(
              label: const Text(
                'At this position',
                style: TextStyle(fontSize: 12),
              ),
              selected: atPosition,
              onSelected: atPositionEnabled ? onAtPositionChanged : null,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Where a drop lands relative to the row under the pointer.
enum _DropPlace { onto, before, after }

/// A row that takes drops.
///
/// With [insertion], the pointer's half of the row decides between "before"
/// and "after" and a line is drawn at that edge; otherwise the whole row
/// lights up and the drop is "onto". [onLinger] fires once the pointer has
/// rested on the row with something it accepts — how a closed folder or
/// chapter opens under a drag.
class _DropTarget extends StatefulWidget {
  final bool Function(OutlineDragData) accepts;
  final void Function(OutlineDragData, _DropPlace) onDrop;
  final VoidCallback? onLinger;
  final bool insertion;
  final Widget child;

  const _DropTarget({
    super.key,
    required this.accepts,
    required this.onDrop,
    required this.child,
    this.onLinger,
    this.insertion = false,
  });

  @override
  State<_DropTarget> createState() => _DropTargetState();
}

class _DropTargetState extends State<_DropTarget> {
  static const _lingerDelay = Duration(milliseconds: 600);

  _DropPlace? _hot;
  Timer? _linger;

  @override
  void dispose() {
    _linger?.cancel();
    super.dispose();
  }

  void _setHot(_DropPlace? place) {
    if (place == _hot) return;
    setState(() => _hot = place);
  }

  _DropPlace _placeFor(Offset global) {
    if (!widget.insertion) return _DropPlace.onto;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return _DropPlace.after;
    return box.globalToLocal(global).dy < box.size.height / 2
        ? _DropPlace.before
        : _DropPlace.after;
  }

  void _leave() {
    _linger?.cancel();
    _linger = null;
    _setHot(null);
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<OutlineDragData>(
      onWillAcceptWithDetails: (d) {
        final ok = widget.accepts(d.data);
        if (ok) {
          _setHot(_placeFor(d.offset));
          final linger = widget.onLinger;
          if (linger != null) {
            _linger?.cancel();
            _linger = Timer(_lingerDelay, linger);
          }
        }
        return ok;
      },
      onMove: (d) {
        if (_hot != null) _setHot(_placeFor(d.offset));
      },
      onLeave: (_) => _leave(),
      onAcceptWithDetails: (d) {
        final place = _hot ?? _placeFor(d.offset);
        _leave();
        widget.onDrop(d.data, place);
      },
      builder: (context, candidates, _) {
        final place = _hot;
        const side = BorderSide(color: AppColors.accent, width: 2);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: place == _DropPlace.onto
                ? AppColors.accent.withValues(alpha: 0.18)
                : null,
            border: switch (place) {
              null => null,
              _DropPlace.onto => Border.all(color: AppColors.accent, width: 1),
              _DropPlace.before => const Border(top: side),
              _DropPlace.after => const Border(bottom: side),
            },
          ),
          child: widget.child,
        );
      },
    );
  }
}

/// What the panel wants to know about a drag: that one started (and with
/// what), where the pointer is, and that it ended — enough to show the foot
/// drop zone and scroll the list near its edges.
class _DragHooks {
  final ValueChanged<OutlineDragData> onStarted;
  final ValueChanged<Offset> onUpdate;
  final VoidCallback onEnded;
  const _DragHooks({
    required this.onStarted,
    required this.onUpdate,
    required this.onEnded,
  });
}

/// Whether a drag should start on the first movement (desktop, where the
/// pointer is a mouse) rather than after a press (touch, where an immediate
/// drag would swallow every scroll). Read from the theme, which is how a
/// widget test names its platform.
bool _mouseFirst(BuildContext context) => switch (Theme.of(context).platform) {
  TargetPlatform.linux ||
  TargetPlatform.windows ||
  TargetPlatform.macOS => true,
  _ => false,
};

/// A row that can be dragged (as [data]) and right-clicked.
class _RowShell extends StatelessWidget {
  final OutlineDragData data;
  final int depth;
  final bool highlighted;
  final VoidCallback? onTap;
  final ValueChanged<Offset> onContextMenu;
  final _DragHooks drag;
  final Widget child;

  /// Text shown under the pointer while dragging; defaults to the node's
  /// name.  Built only when a drag actually starts.
  final String Function()? feedbackLabel;

  const _RowShell({
    required this.data,
    required this.depth,
    required this.onContextMenu,
    required this.drag,
    required this.child,
    this.onTap,
    this.highlighted = false,
    this.feedbackLabel,
  });

  @override
  Widget build(BuildContext context) {
    final row = InkWell(
      onTap: onTap,
      child: Container(
        color: highlighted ? AppColors.accent.withValues(alpha: 0.12) : null,
        padding: EdgeInsets.only(left: 8.0 + depth * 14, right: 6),
        height: OutlineRow.height,
        child: child,
      ),
    );
    // The feedback hangs just below-right of the pointer, so the pointer —
    // which is what the drop targets read — stays visible over the row it
    // is about to land on.
    final feedback = Transform.translate(
      offset: const Offset(10, 10),
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          constraints: const BoxConstraints(maxWidth: 240),
          // The label is only ever laid out in the drag overlay, so the
          // Builder defers its (string-building) work until then.
          child: Builder(
            builder: (_) => Text(
              feedbackLabel?.call() ?? data.node.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.ink),
            ),
          ),
        ),
      ),
    );
    final dragging = Opacity(opacity: 0.4, child: row);
    void started() => drag.onStarted(data);
    void update(DragUpdateDetails d) => drag.onUpdate(d.globalPosition);
    void ended(DraggableDetails _) => drag.onEnded();

    // A mouse drags the moment it moves; a finger has to press first, or
    // every scroll of the list would pick a row up instead.
    final draggable = _mouseFirst(context)
        ? Draggable<OutlineDragData>(
            data: data,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: feedback,
            childWhenDragging: dragging,
            onDragStarted: started,
            onDragUpdate: update,
            onDragEnd: ended,
            child: row,
          )
        : LongPressDraggable<OutlineDragData>(
            data: data,
            delay: const Duration(milliseconds: 250),
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: feedback,
            childWhenDragging: dragging,
            onDragStarted: started,
            onDragUpdate: update,
            onDragEnd: ended,
            child: row,
          );
    return GestureDetector(
      onSecondaryTapUp: (d) => onContextMenu(d.globalPosition),
      onLongPressStart: (d) => onContextMenu(d.globalPosition),
      child: draggable,
    );
  }
}

class _FolderRow extends StatelessWidget {
  final OutlineFolder folder;
  final int depth;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<Offset> onContextMenu;
  final _DragHooks drag;

  const _FolderRow({
    required this.folder,
    required this.depth,
    required this.expanded,
    required this.onToggle,
    required this.onContextMenu,
    required this.drag,
  });

  @override
  Widget build(BuildContext context) {
    return _RowShell(
      data: OutlineDragData(folder),
      depth: depth,
      onTap: onToggle,
      onContextMenu: onContextMenu,
      drag: drag,
      child: Row(
        children: [
          Icon(
            expanded ? Icons.expand_more : Icons.chevron_right,
            size: 16,
            color: AppColors.onSurfaceMuted,
          ),
          const SizedBox(width: 2),
          Icon(
            expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
            size: 16,
            color: AppColors.onSurfaceSoft,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              folder.name,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _Count(folder.lineCount),
        ],
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  final OutlineChapter chapter;
  final int depth;
  final bool active;
  final bool open;
  final String? badge;
  final int visibleLines;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final ValueChanged<Offset> onContextMenu;
  final _DragHooks drag;

  const _ChapterRow({
    required this.chapter,
    required this.depth,
    required this.active,
    required this.open,
    this.badge,
    required this.visibleLines,
    required this.onTap,
    required this.onToggle,
    required this.onContextMenu,
    required this.drag,
  });

  @override
  Widget build(BuildContext context) {
    return _RowShell(
      data: OutlineDragData(chapter),
      depth: depth,
      highlighted: active,
      onTap: onTap,
      onContextMenu: onContextMenu,
      drag: drag,
      child: Row(
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                open ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: AppColors.onSurfaceMuted,
              ),
            ),
          ),
          Icon(
            Icons.article_outlined,
            size: 15,
            color: active ? AppColors.accent : AppColors.onSurfaceSoft,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              chapter.name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? AppColors.ink : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (badge != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                badge!,
                style: const TextStyle(fontSize: 12, color: AppColors.accent),
              ),
            ),
            const SizedBox(width: 6),
          ],
          _Count(visibleLines),
        ],
      ),
    );
  }
}

class _SectionRow extends StatelessWidget {
  final String title;
  final int depth;
  final int count;
  const _SectionRow({
    super.key,
    required this.title,
    required this.depth,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: OutlineRow.height,
      alignment: Alignment.bottomLeft,
      padding: EdgeInsets.only(
        left: 12.0 + depth * 14,
        right: 8,
        top: 4,
        bottom: 4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w700,
                color: AppColors.onSurfaceMuted,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _Count(count),
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  final OutlineLine line;
  final int depth;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Offset> onContextMenu;
  final OutlineDragData dragData;
  final _DragHooks drag;

  const _LineRow({
    required this.line,
    required this.depth,
    required this.selected,
    required this.onTap,
    required this.onContextMenu,
    required this.dragData,
    required this.drag,
  });

  @override
  Widget build(BuildContext context) {
    final n = dragData.lineCount;
    return _RowShell(
      data: dragData,
      depth: depth,
      highlighted: selected,
      onTap: onTap,
      onContextMenu: onContextMenu,
      drag: drag,
      feedbackLabel: () =>
          n > 1 ? '$n lines' : '${line.name} · ${line.preview(maxPlies: 4)}',
      child: Row(
        children: [
          Icon(
            line.isModelGame ? Icons.local_library_outlined : Icons.timeline,
            size: 13,
            color: selected ? AppColors.accent : AppColors.onSurfaceDim,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    line.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      fontStyle: line.isModelGame ? FontStyle.italic : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    line.previewLabel,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: AppTextStyles.monoFamily,
                      color: AppColors.onSurfaceMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Text('${line.moves.length}', style: AppTextStyles.caption),
        ],
      ),
    );
  }
}

/// The drop zone at the foot of the list, shown only during a drag.
class _FootZone extends StatelessWidget {
  final String label;
  const _FootZone({required this.label});

  @override
  Widget build(BuildContext context) => Container(
    height: OutlineRow.height,
    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      border: Border.all(color: AppColors.onSurfaceDim),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted),
      overflow: TextOverflow.ellipsis,
    ),
  );
}

class _Count extends StatelessWidget {
  final int n;
  const _Count(this.n);
  @override
  Widget build(BuildContext context) =>
      Text('$n', style: AppTextStyles.caption);
}

class _Hint extends StatelessWidget {
  final int depth;
  final String text;
  const _Hint({super.key, required this.depth, required this.text});
  @override
  Widget build(BuildContext context) => Container(
    height: OutlineRow.height,
    alignment: Alignment.centerLeft,
    padding: EdgeInsets.only(left: 12.0 + depth * 14, right: 8),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        color: AppColors.onSurfaceDim,
        fontStyle: FontStyle.italic,
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;
  const _Empty({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: AppColors.onSurfaceDim),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: AppTextStyles.caption,
            ),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}
