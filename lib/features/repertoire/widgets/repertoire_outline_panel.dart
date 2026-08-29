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
/// The panel does not know about the board. It reports what the user picked
/// ([onOpenChapter], [onOpenLine]) and what they asked for
/// ([onGenerateInto], [onAuditChapter], [onTrainChapter]) and lets the screen
/// act.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../theme/app_colors.dart';
import '../controllers/repertoire_outline_controller.dart';
import '../models/outline_rows.dart';
import '../models/repertoire_outline.dart';
import '../services/repertoire_outline_service.dart';

/// Payload of a drag from the outline: a line, chapter or folder.
class OutlineDragData {
  final OutlineNode node;
  const OutlineDragData(this.node);
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
  String _search = '';
  bool _atPosition = false;
  Timer? _debounce;

  RepertoireOutlineController get _c => widget.controller;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
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
              onNewFolder: outline == null
                  ? null
                  : () => _promptCreateFolder(outline.path),
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
            'chapter, then fill it from the Add lines menu.',
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
    // attached across rebuilds.
    return ListView.builder(
      primary: false,
      padding: const EdgeInsets.only(bottom: 24),
      itemExtent: OutlineRow.height,
      itemCount: rows.length,
      itemBuilder: (context, index) => _buildRow(rows[index]),
    );
  }

  // ── Tree rows ──────────────────────────────────────────────────────────

  Widget _buildRow(OutlineRow row) {
    switch (row) {
      case FolderRow(:final folder, :final depth, :final expanded):
        return _DropTarget(
          key: ValueKey(row.key),
          accepts: (d) => _canDropOnFolder(d, folder),
          onDrop: (d) => _dropOnFolder(d, folder),
          child: _FolderRow(
            folder: folder,
            depth: depth,
            expanded: expanded,
            onToggle: () => _c.toggleFolder(folder.path),
            onContextMenu: (pos) => _folderMenu(pos, folder),
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
          onDrop: (d) => _dropOnChapter(d, chapter),
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
        return _LineRow(
          key: ValueKey(row.key),
          line: line,
          depth: depth,
          selected: selected,
          onTap: () => widget.onOpenLine(chapter.path, line),
          onContextMenu: (pos) => _lineMenu(pos, chapter, line),
        );
      case HintRow(:final depth, :final text):
        return _Hint(key: ValueKey(row.key), depth: depth, text: text);
    }
  }

  // ── Drag & drop rules ──────────────────────────────────────────────────

  bool _canDropOnFolder(OutlineDragData d, OutlineFolder target) {
    switch (d.node) {
      case OutlineFolder f:
        return !f.contains(target.path) &&
            !p.equals(p.dirname(f.path), target.path);
      case OutlineChapter c:
        return !p.equals(p.dirname(c.path), target.path);
      case OutlineLine _:
        return false;
    }
  }

  bool _canDropOnChapter(OutlineDragData d, OutlineChapter target) {
    final node = d.node;
    return node is OutlineLine && !p.equals(node.path, target.path);
  }

  Future<void> _dropOnFolder(OutlineDragData d, OutlineFolder target) async {
    switch (d.node) {
      case OutlineFolder f:
        _report(await _c.moveFolder(f.path, target.path));
      case OutlineChapter c:
        _report(await _c.moveChapter(c.path, target.path));
      case OutlineLine _:
        break;
    }
  }

  Future<void> _dropOnChapter(OutlineDragData d, OutlineChapter target) async {
    final line = d.node as OutlineLine;
    _report(
      await _c.moveLine(
        fromChapterPath: line.path,
        gameIndex: line.gameIndex,
        toChapterPath: target.path,
      ),
    );
  }

  // ── Context menus ──────────────────────────────────────────────────────

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
        final name = await _promptName('Rename folder', folder.name);
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
        if (await _confirm(
          'Delete folder "${folder.name}"?',
          '${folder.allChapters.length} chapter(s) and ${folder.lineCount} '
              'line(s) inside it will be deleted. This cannot be undone.',
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
        final name = await _promptName('Rename chapter', chapter.name);
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
        if (await _confirm(
          'Delete chapter "${chapter.name}"?',
          '${chapter.lineCount} line(s) will be deleted. This cannot be undone.',
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
    final action = await _showMenu(pos, [
      const _MenuEntry('open', 'Load on the board', Icons.launch),
      if (widget.onTrainLine != null)
        const _MenuEntry('train', 'Train this line', Icons.school_outlined),
      const _MenuEntry.divider(),
      const _MenuEntry('rename', 'Rename…', Icons.drive_file_rename_outline),
      const _MenuEntry(
        'move',
        'Move to chapter…',
        Icons.drive_file_move_outline,
      ),
      const _MenuEntry.divider(),
      const _MenuEntry(
        'delete',
        'Delete line…',
        Icons.delete_outline,
        danger: true,
      ),
    ]);
    switch (action) {
      case 'open':
        widget.onOpenLine(chapter.path, line);
      case 'train':
        widget.onTrainLine?.call(chapter.path, line);
      case 'rename':
        final name = await _promptName('Rename line', line.name);
        if (name != null) {
          _report(await _c.renameLine(chapter.path, line.gameIndex, name));
        }
      case 'move':
        final target = await _pickChapter(exclude: chapter.path);
        if (target != null) {
          _report(
            await _c.moveLine(
              fromChapterPath: chapter.path,
              gameIndex: line.gameIndex,
              toChapterPath: target.path,
            ),
          );
        }
      case 'delete':
        if (await _confirm(
          'Delete "${line.name}"?',
          'This cannot be undone.',
        )) {
          _report(await _c.deleteLine(chapter.path, line.gameIndex));
        }
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
                        fontSize: 12.5,
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
    if (!await _confirm(
      'Split "${chapter.name}" into ${titles.length} chapters?',
      '$moving line(s) move into new chapter files named after the course\'s '
          'own chapters, and their training progress moves with them.\n\n'
          '${staying == 0 ? '"${chapter.name}" is left empty and removed.' : '$staying untitled line(s) stay in "${chapter.name}".'}',
      confirmLabel: 'Split',
      danger: false,
    )) {
      return;
    }
    _report(await _c.splitChapter(chapter.path));
  }

  Future<void> _promptCreateChapter(String folderPath) async {
    final name = await _promptName('New chapter', '');
    if (name == null) return;
    _report(await _c.createChapter(folderPath: folderPath, name: name));
    if (!mounted) return;
    // A brand-new chapter is what the user wants to work in next.
    final created = _c.outline?.allChapters.where(
      (c) => p.equals(c.path, p.join(folderPath, '$name.pgn')),
    );
    if (created != null && created.isNotEmpty) {
      widget.onOpenChapter(created.first.path);
    }
  }

  Future<void> _promptCreateFolder(String parentPath) async {
    final name = await _promptName('New folder', '');
    if (name == null) return;
    _report(await _c.createFolder(parentPath: parentPath, name: name));
  }

  Future<String?> _promptName(String title, String initial) {
    return showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(title: title, initial: initial),
    );
  }

  /// [confirmLabel] names what the button does; it is red only for the
  /// deletions, so a reorganisation does not read as a destruction.
  Future<bool> _confirm(
    String title,
    String body, {
    String confirmLabel = 'Delete',
    bool danger = true,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: danger
                ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
                : null,
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

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

  void _report(OutlineEditOutcome outcome) {
    if (outcome.ok || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(outcome.error!)));
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
  final VoidCallback? onNewFolder;
  final VoidCallback? onShowMetrics;
  final VoidCallback? onCollapse;

  const _Header({
    required this.title,
    required this.chapterCount,
    required this.lineCount,
    required this.loading,
    required this.onNewChapter,
    required this.onNewFolder,
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
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.onSurfaceMuted,
                  ),
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
          MenuAnchor(
            menuChildren: [
              MenuItemButton(
                leadingIcon: const Icon(Icons.note_add_outlined, size: 18),
                onPressed: onNewChapter,
                child: const Text('New chapter…'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(
                  Icons.create_new_folder_outlined,
                  size: 18,
                ),
                onPressed: onNewFolder,
                child: const Text('New folder…'),
              ),
            ],
            builder: (context, controller, _) => IconButton(
              tooltip: 'New chapter or folder',
              icon: const Icon(Icons.add, size: 20),
              visualDensity: VisualDensity.compact,
              onPressed: onNewChapter == null
                  ? null
                  : () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
            ),
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
                style: TextStyle(fontSize: 11),
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

class _DropTarget extends StatelessWidget {
  final bool Function(OutlineDragData) accepts;
  final ValueChanged<OutlineDragData> onDrop;
  final Widget child;
  const _DropTarget({
    super.key,
    required this.accepts,
    required this.onDrop,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<OutlineDragData>(
      onWillAcceptWithDetails: (d) => accepts(d.data),
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, candidates, _) {
        final hot = candidates.isNotEmpty;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: hot ? AppColors.accent.withValues(alpha: 0.18) : null,
            border: hot ? Border.all(color: AppColors.accent, width: 1) : null,
          ),
          child: child,
        );
      },
    );
  }
}

/// A row that can be dragged (as [node]) and right-clicked.
class _RowShell extends StatelessWidget {
  final OutlineNode node;
  final int depth;
  final bool highlighted;
  final VoidCallback? onTap;
  final ValueChanged<Offset> onContextMenu;
  final Widget child;

  /// Text shown under the pointer while dragging; defaults to the node's
  /// name.  Built only when a drag actually starts.
  final String Function()? feedbackLabel;

  const _RowShell({
    required this.node,
    required this.depth,
    required this.onContextMenu,
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
    return GestureDetector(
      onSecondaryTapUp: (d) => onContextMenu(d.globalPosition),
      onLongPressStart: (d) => onContextMenu(d.globalPosition),
      child: LongPressDraggable<OutlineDragData>(
        data: OutlineDragData(node),
        delay: const Duration(milliseconds: 250),
        feedback: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            constraints: const BoxConstraints(maxWidth: 240),
            // The label is only ever laid out in the drag overlay, so the
            // Builder defers its (string-building) work until then.
            child: Builder(
              builder: (_) => Text(
                feedbackLabel?.call() ?? node.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppColors.ink),
              ),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: row),
        child: row,
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  final OutlineFolder folder;
  final int depth;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<Offset> onContextMenu;

  const _FolderRow({
    required this.folder,
    required this.depth,
    required this.expanded,
    required this.onToggle,
    required this.onContextMenu,
  });

  @override
  Widget build(BuildContext context) {
    return _RowShell(
      node: folder,
      depth: depth,
      onTap: onToggle,
      onContextMenu: onContextMenu,
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
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
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
  });

  @override
  Widget build(BuildContext context) {
    return _RowShell(
      node: chapter,
      depth: depth,
      highlighted: active,
      onTap: onTap,
      onContextMenu: onContextMenu,
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
                fontSize: 12.5,
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
                style: const TextStyle(fontSize: 10, color: AppColors.accent),
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
                fontSize: 10,
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

  const _LineRow({
    super.key,
    required this.line,
    required this.depth,
    required this.selected,
    required this.onTap,
    required this.onContextMenu,
  });

  @override
  Widget build(BuildContext context) {
    return _RowShell(
      node: line,
      depth: depth,
      highlighted: selected,
      onTap: onTap,
      onContextMenu: onContextMenu,
      feedbackLabel: () => '${line.name} · ${line.preview(maxPlies: 4)}',
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
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: AppColors.onSurfaceMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${line.moves.length}',
            style: const TextStyle(fontSize: 10, color: AppColors.onSurfaceDim),
          ),
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  final int n;
  const _Count(this.n);
  @override
  Widget build(BuildContext context) => Text(
    '$n',
    style: const TextStyle(fontSize: 11, color: AppColors.onSurfaceMuted),
  );
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
        fontSize: 11,
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
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceMuted,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  final String title;
  final String initial;
  const _NameDialog({required this.title, required this.initial});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final problem = RepertoireOutlineService.validateName(_controller.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _controller,
          autofocus: true,
          onSubmitted: (_) => _submit(),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          decoration: InputDecoration(labelText: 'Name', errorText: _error),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}
