/// Interactive PGN editor widget for repertoire building.
///
/// Pure view: receives a [MoveTree] + [TreePath] from the controller and
/// fires callbacks for user actions.  No internal move state.
library;

import 'dart:async';

import 'package:chess_auto_prep/utils/pgn_nags.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/pgn_text_styles.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/utils/app_messages.dart';
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart'
    show commentProse, mergeCommentProse;
import 'package:chess_auto_prep/utils/chess_utils.dart' show isNullMoveSan;
import 'package:chess_auto_prep/utils/training_markers.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart'
    show MoveChip;
import 'pgn/comment_editor.dart';
import 'pgn/comment_prose_spans.dart';
import 'pgn/pgn_annotation_panel.dart';

class InteractivePgnEditor extends StatefulWidget {
  /// The move tree to display (owned by controller).
  final MoveTree tree;

  /// Current cursor path (owned by controller).
  final TreePath currentPath;

  /// Jump the cursor to a different path (click on a move).
  final ValueChanged<TreePath>? onJump;

  /// Called when the user edits a comment.
  final void Function(TreePath path, String? comment)? onCommentChanged;

  /// Called to toggle a move-quality NAG glyph on a move.  When null the
  /// glyph toolbar is hidden (the surface doesn't support annotation glyphs).
  final void Function(TreePath path, int nagId)? onToggleNag;

  /// Called to delete a subtree.
  final void Function(TreePath path)? onDelete;

  /// Called to promote a variation one step.
  final void Function(TreePath path)? onPromote;

  /// Called to recursively promote a variation to the main line.
  final void Function(TreePath path)? onMakeMainLine;

  /// Called when the user edits an existing line.
  final void Function(String updatedPgn)? onLineEdited;

  /// Called after debounced edits while [isEditingExistingLine] is true.
  /// Falls back to [onLineEdited] when null.
  final ValueChanged<String>? onAutoSave;

  /// Called when comment edits mark the line dirty.
  final VoidCallback? onDirty;

  /// Copies PGN text to the clipboard and shows [successMessage] on success.
  final void Function(String text, String successMessage)? onCopyToClipboard;

  /// Called when the user chooses "View in Lines" from the context menu.
  final VoidCallback? onViewInLines;

  /// Whether the editor is showing an existing line being edited in-place.
  final bool isEditingExistingLine;

  /// Title of the line being edited (the PGN Event header). Shown in the
  /// title field and written back on save so autosaves don't clobber it.
  final String? lineTitle;

  final String? repertoireColor;

  /// Read-only header shown instead of the title field for ephemeral lines
  /// (e.g. "Trap #45 · Sicilian Defense").
  final String? ephemeralTitle;

  /// Show the persistent annotation panel (comment field, NAG glyphs, puzzle
  /// markers) even when this host saves through a controller rather than the
  /// editor's own line-save callbacks (which imply the panel on their own).
  final bool showAnnotationPanel;

  const InteractivePgnEditor({
    super.key,
    required this.tree,
    required this.currentPath,
    this.onJump,
    this.onCommentChanged,
    this.onToggleNag,
    this.onDelete,
    this.onPromote,
    this.onMakeMainLine,
    this.onLineEdited,
    this.onAutoSave,
    this.onDirty,
    this.onCopyToClipboard,
    this.onViewInLines,
    this.isEditingExistingLine = false,
    this.lineTitle,
    this.repertoireColor,
    this.ephemeralTitle,
    this.showAnnotationPanel = false,
  });

  @override
  State<InteractivePgnEditor> createState() => _InteractivePgnEditorState();
}

class _InteractivePgnEditorState extends State<InteractivePgnEditor> {
  final TextEditingController _titleController = TextEditingController();
  TreePath? _contextMenuPath;
  bool _contextMenuOpen = false;

  /// Move whose comment is being edited inline (viewer-style editor shown in
  /// the move flow), or null.
  TreePath? _editingCommentPath;

  Timer? _autoSaveTimer;
  static const _autoSaveDelay = Duration(seconds: 2);

  /// The rendered movetext, kept across cursor moves.
  ///
  /// Keyed on the tree's identity and [MoveTree.version], not on the cursor:
  /// the rows are the same widgets whichever move is selected, and the
  /// selection is painted by each chip listening to [_selection].  Stepping
  /// through a line therefore rebuilds two chips, not a paragraph per node —
  /// the lichess-mobile move list does the same with cached segments.
  List<Widget>? _cachedMoveWidgets;
  MoveTree? _cachedTree;
  int _cachedVersion = -1;

  /// The cursor, for the chips.  Updated in [didUpdateWidget] so the two
  /// chips whose state changed repaint without the paragraph rebuilding.
  late final ValueNotifier<TreePath> _selection = ValueNotifier(
    widget.currentPath,
  );

  @override
  void initState() {
    super.initState();
    _titleController.text = widget.lineTitle ?? '';
  }

  @override
  void didUpdateWidget(InteractivePgnEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lineTitle != oldWidget.lineTitle) {
      _titleController.text = widget.lineTitle ?? '';
    }
    if (!identical(widget.tree, oldWidget.tree)) {
      _editingCommentPath = null;
    }
    if (widget.currentPath != _selection.value) {
      _selection.value = widget.currentPath;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _selection.dispose();
    _autoSaveTimer?.cancel();
    super.dispose();
  }

  // ── Callbacks into controller ─────────────────────────────────────

  void _jumpTo(TreePath path) => widget.onJump?.call(path);

  void _startEditingComment(TreePath path) {
    _jumpTo(path);
    setState(() => _editingCommentPath = path);
  }

  void _saveInlineComment(TreePath path, String comment) {
    final trimmed = comment.trim();
    widget.onCommentChanged?.call(path, trimmed.isEmpty ? null : trimmed);
    widget.onDirty?.call();
    _scheduleAutoSave();
    setState(() => _editingCommentPath = null);
  }

  /// Comment committed from the persistent bottom annotation panel.
  void _commitPanelComment(TreePath path, String text) {
    final node = widget.tree.nodeAt(path);
    if (node == null) return;
    final trimmed = text.trim();
    final normalized = trimmed.isEmpty ? null : trimmed;
    if (node.comment == normalized) return;
    widget.onCommentChanged?.call(path, normalized);
    widget.onDirty?.call();
    _scheduleAutoSave();
    if (mounted) setState(() {});
  }

  void _togglePanelNag(TreePath path, int nagId) {
    // Hosts with a controller own the mutation (keeps core → widgets layering);
    // fall back to editing the tree directly for hosts that don't pass one.
    if (widget.onToggleNag != null) {
      widget.onToggleNag!(path, nagId);
    } else {
      final node = widget.tree.nodeAt(path);
      if (node == null) return;
      final next = toggleQualityNag(node.nags, nagId);
      node.nags = next.isEmpty ? null : next;
      // Edited behind the tree's back, so tell it — the movetext cache
      // keys on the version.
      widget.tree.markMutated();
    }
    widget.onDirty?.call();
    _scheduleAutoSave();
    setState(() {});
  }

  /// Toggle the puzzle start/end marker on the move at [path]. The marker is
  /// a `[%tstart]`/`[%tend]` comment token, so it persists through the host's
  /// normal comment channel and survives any PGN round-trip.
  void _togglePuzzleMarker(TreePath path, {required bool start}) {
    final onCommentChanged = widget.onCommentChanged;
    if (onCommentChanged == null) return;
    togglePuzzleMarker(
      widget.tree,
      path,
      start: start,
      setComment: (p, comment) {
        onCommentChanged(p, comment);
      },
    );
    widget.onDirty?.call();
    _scheduleAutoSave();
    setState(() {});
  }

  void _deleteFromHere() {
    if (_contextMenuPath == null) return;
    widget.onDelete?.call(_contextMenuPath!);
  }

  void _promoteVariation() {
    if (_contextMenuPath == null) return;
    widget.onPromote?.call(_contextMenuPath!);
  }

  void _makeMainLine() {
    if (_contextMenuPath == null) return;
    widget.onMakeMainLine?.call(_contextMenuPath!);
  }

  void _duplicateLine() {
    if (_contextMenuPath == null) return;
    final moves = widget.tree.sanSequenceAt(_contextMenuPath!);
    if (moves.isEmpty) return;
    final mainlineEnd = widget.tree.mainlineEndFrom(_contextMenuPath!);
    final fullMoves = [
      ...moves,
      ...widget.tree.sanSequenceAt(mainlineEnd).skip(moves.length),
    ];
    final subtree = MoveTree.fromMoves(
      fullMoves,
      startingFen: widget.tree.startingFen,
    );
    final text = subtree.toPgnMoveText();
    widget.onCopyToClipboard?.call(text, 'Line copied to clipboard');
  }

  void _copyPgnFromHere() {
    if (_contextMenuPath == null) return;
    final node = widget.tree.nodeAt(_contextMenuPath!);
    if (node == null) return;
    final subtree = MoveTree(
      startingFen: widget.tree.fenAt(_contextMenuPath!.parent),
      roots: [node],
    );
    final text = subtree.toPgnMoveText();
    widget.onCopyToClipboard?.call(text, AppMessages.pgnCopied);
  }

  void _scheduleAutoSave() {
    if (!widget.isEditingExistingLine) return;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(_autoSaveDelay, () {
      if (!mounted) return;
      final pgn = _buildFullPgnForSave();
      final onSave = widget.onAutoSave ?? widget.onLineEdited;
      onSave?.call(pgn);
    });
  }

  String _buildFullPgnForSave() {
    final typed = _titleController.text.trim();
    final title = typed.isNotEmpty
        ? typed
        : (widget.lineTitle?.trim().isNotEmpty ?? false)
        ? widget.lineTitle!.trim()
        : 'Repertoire Line';
    return widget.tree.toPgn(
      event: title,
      white: _whiteHeader(),
      black: _blackHeader(),
      result: '*',
    );
  }

  String _whiteHeader() {
    final c = (widget.repertoireColor ?? 'White').trim().toLowerCase();
    return c == 'black' ? 'Training' : 'Me';
  }

  String _blackHeader() {
    final c = (widget.repertoireColor ?? 'White').trim().toLowerCase();
    return c == 'black' ? 'Me' : 'Training';
  }

  // ── Context menu ──────────────────────────────────────────────────

  void _showContextMenu(TreePath path, Offset globalPosition) {
    unawaited(_runContextMenu(path, globalPosition));
  }

  Future<void> _runContextMenu(TreePath path, Offset globalPosition) async {
    _contextMenuPath = path;
    setState(() => _contextMenuOpen = true);

    String moveName = 'Move';
    final node = widget.tree.nodeAt(path);
    if (node != null) moveName = node.san;
    final isOnMainline = path.isMainline;
    final hasComment = node?.comment?.isNotEmpty ?? false;

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );

    final value = await showMenu<String>(
      context: context,
      position: position,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        PopupMenuItem(
          enabled: false,
          height: 32,
          child: Text(
            moveName,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        const PopupMenuDivider(height: 1),
        PopupMenuItem(
          value: 'comment',
          child: _PopupMenuRow(
            icon: Icons.comment,
            text: hasComment ? 'Edit Comment' : 'Add Comment',
          ),
        ),
        if (widget.onCommentChanged != null) ...[
          PopupMenuItem(
            value: 'puzzle_start',
            child: _PopupMenuRow(
              icon: Icons.flag,
              text: hasPuzzleStart(node?.comment)
                  ? 'Clear Puzzle Start'
                  : 'Puzzle Starts Here',
            ),
          ),
          PopupMenuItem(
            value: 'puzzle_end',
            child: _PopupMenuRow(
              icon: Icons.sports_score,
              text: hasPuzzleEnd(node?.comment)
                  ? 'Clear Puzzle End'
                  : 'Puzzle Ends Here',
            ),
          ),
        ],
        if (!isOnMainline)
          const PopupMenuItem(
            value: 'promote',
            child: _PopupMenuRow(
              icon: Icons.arrow_upward,
              text: 'Promote Variation',
            ),
          ),
        if (!isOnMainline)
          const PopupMenuItem(
            value: 'mainline',
            child: _PopupMenuRow(
              icon: Icons.vertical_align_top,
              text: 'Make Main Line',
            ),
          ),
        // Copies root→leaf through this move (the old "Duplicate Line" label
        // promised an edit it never performed).
        const PopupMenuItem(
          value: 'duplicate',
          child: _PopupMenuRow(icon: Icons.copy_all, text: 'Copy Whole Line'),
        ),
        const PopupMenuItem(
          value: 'copy',
          child: _PopupMenuRow(
            icon: Icons.content_copy,
            text: 'Copy PGN from Here',
          ),
        ),
        if (widget.isEditingExistingLine && widget.onViewInLines != null)
          const PopupMenuItem(
            value: 'viewlines',
            child: _PopupMenuRow(icon: Icons.list_alt, text: 'View in Lines'),
          ),
        const PopupMenuDivider(height: 1),
        const PopupMenuItem(
          value: 'delete',
          child: _PopupMenuRow(
            icon: Icons.delete_outline,
            text: 'Delete from Here',
          ),
        ),
      ],
    );
    if (!mounted) return;
    setState(() => _contextMenuOpen = false);
    if (value == null) return;
    switch (value) {
      case 'comment':
        _startEditingComment(path);
      case 'puzzle_start':
        _togglePuzzleMarker(path, start: true);
      case 'puzzle_end':
        _togglePuzzleMarker(path, start: false);
      case 'promote':
        _promoteVariation();
      case 'mainline':
        _makeMainLine();
      case 'duplicate':
        _duplicateLine();
      case 'copy':
        _copyPgnFromHere();
      case 'viewlines':
        widget.onViewInLines?.call();
      case 'delete':
        _deleteFromHere();
    }
  }

  // ── Build ─────────────────────────────────────────────────────────

  /// The title field only makes sense where the editor persists whole lines
  /// (repertoire builder). Hosts with their own naming UI (study chapters)
  /// pass no save callbacks and get a clean movetext-only surface.
  bool get _showTitleField =>
      widget.onLineEdited != null || widget.onAutoSave != null;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.pgnSurface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.ephemeralTitle != null) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              size: 14,
                              color: AppColors.warning,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                widget.ephemeralTitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.warning,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1, color: AppColors.divider),
                      const SizedBox(height: 4),
                    ] else if (_showTitleField) ...[
                      Row(
                        children: [
                          const Icon(
                            Icons.drive_file_rename_outline,
                            size: 15,
                            color: AppColors.onSurfaceMuted,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: TextField(
                              controller: _titleController,
                              decoration: const InputDecoration(
                                hintText: 'Line title',
                                hintStyle: TextStyle(
                                  color: AppColors.onSurfaceMuted,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                              ),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.inkSoft,
                              ),
                              onChanged: (_) {
                                widget.onDirty?.call();
                                _scheduleAutoSave();
                              },
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 1, color: AppColors.divider),
                      const SizedBox(height: 4),
                    ],
                    Expanded(
                      child: SingleChildScrollView(child: _buildMovesDisplay()),
                    ),
                  ],
                ),
              ),
            ),
            if (_showTitleField || widget.showAnnotationPanel)
              _buildAnnotationPanel(),
          ],
        ),
      ],
    );
  }

  /// Persistent annotation strip pinned below the move list: the move the
  /// cursor sits on is always editable here, no right-click needed.
  Widget _buildAnnotationPanel() {
    final path = widget.currentPath;
    final node = path.isEmpty ? null : widget.tree.nodeAt(path);
    final canMark = widget.onCommentChanged != null;
    return PgnAnnotationPanel(
      targetKey: node == null ? null : 'n${node.id}',
      moveLabel: node == null ? '' : _moveLabelFor(path, node),
      nags: node?.nags ?? const [],
      comment: node?.comment ?? '',
      onToggleNag: (nagId) => _togglePanelNag(path, nagId),
      onCommentChanged: (text) => _commitPanelComment(path, text),
      puzzleStart: hasPuzzleStart(node?.comment),
      puzzleEnd: hasPuzzleEnd(node?.comment),
      onTogglePuzzleStart: canMark
          ? () => _togglePuzzleMarker(path, start: true)
          : null,
      onTogglePuzzleEnd: canMark
          ? () => _togglePuzzleMarker(path, start: false)
          : null,
    );
  }

  String _moveLabelFor(TreePath path, MoveNode node) {
    final (startMoveNumber, startIsWhite) = MoveTree.moveNumberFromFen(
      widget.tree.startingFen,
    );
    final ply = path.length - 1;
    final isWhiteMove = startIsWhite ? ply.isEven : ply.isOdd;
    final moveNumber = startMoveNumber + ((startIsWhite ? ply : ply + 1) ~/ 2);
    return '$moveNumber${isWhiteMove ? '.' : '...'} ${node.san}';
  }

  Widget _buildMovesDisplay() {
    if (widget.tree.isEmpty) {
      return const SizedBox.shrink();
    }

    final (startMoveNumber, startIsWhite) = MoveTree.moveNumberFromFen(
      widget.tree.startingFen,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _buildMoveRows(startMoveNumber, startIsWhite),
    );
  }

  // Note: this renders SAN straight from the tree — no dartchess replay. The
  // editor used to thread a Position through the whole recursion (a full
  // parseSan/play replay of every node on each rebuild) without ever using it.
  //
  // Everything inline lives in Text.rich paragraphs: move numbers, parens and
  // comments are TextSpans; move chips are baseline-aligned WidgetSpans — the
  // same construction as the PGN viewer's movetext. A plain Wrap of
  // mixed-height widgets top-aligns each run, which floated every number a
  // few pixels above its move. Only the block comment editor breaks a
  // paragraph.
  List<Widget> _buildMoveRows(int startMoveNumber, bool startIsWhite) {
    // The context-path highlight and the inline editor are transient render
    // state, so neither may be served from nor written to the cache.
    final canCache = !_contextMenuOpen && _editingCommentPath == null;
    if (canCache &&
        _cachedMoveWidgets != null &&
        identical(widget.tree, _cachedTree) &&
        widget.tree.version == _cachedVersion) {
      return _cachedMoveWidgets!;
    }

    final rows = <Widget>[];
    final spans = <InlineSpan>[];

    void flushSpans() {
      if (spans.isEmpty) return;
      rows.add(
        Text.rich(
          TextSpan(style: PgnTextStyles.rowRootAt(0), children: List.of(spans)),
        ),
      );
      spans.clear();
    }

    // Drops the separator space before a closing paren so variations read
    // "(1... c5)" rather than "(1... c5 )".
    void trimSeparator() {
      final last = spans.isEmpty ? null : spans.last;
      if (last is TextSpan && last.text == ' ') spans.removeLast();
    }

    void appendNumber(int moveNumber, bool white, int depth) {
      // NBSP glues the number to its move so a line break can never strand
      // "12." at the end of a line.
      spans.add(
        TextSpan(
          text: white ? '$moveNumber.\u00A0' : '$moveNumber...\u00A0',
          style: PgnTextStyles.moveNumberAt(depth),
        ),
      );
    }

    void appendMove(MoveNode node, TreePath path, int depth) {
      if (hasPuzzleStart(node.comment)) spans.add(_markerSpan(start: true));
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: _buildSingleMoveWidget(node, path, depth),
        ),
      );
      if (hasPuzzleEnd(node.comment)) spans.add(_markerSpan(start: false));
      spans.add(const TextSpan(text: ' '));
    }

    // Appends the node's comment prose or its inline editor. Returns whether
    // the flow was interrupted — a following Black move restates "N...".
    bool appendAnnotations(MoveNode node, TreePath path, int depth) {
      if (_editingCommentPath == path) {
        flushSpans();
        rows.add(_buildInlineCommentEditor(node, path));
        return true;
      }
      final comment = node.comment;
      if (comment == null || comment.isEmpty) return false;
      final prose = commentProseSpans(
        comment,
        style: PgnTextStyles.commentAt(depth),
      );
      if (prose.isEmpty) return false;
      spans.addAll(prose);
      return true;
    }

    void appendSiblings(
      List<MoveNode> siblings,
      int moveNumber,
      bool isWhite,
      int depth, {
      bool isFirstMove = false,
      bool renumber = false,
      required TreePath parentPath,
    }) {
      if (siblings.isEmpty) return;

      final main = siblings[0];
      final mainPath = parentPath.child(0);

      // Null moves ('--') anchor comments to a position; show the comment but
      // never the SAN itself (matches the PGN viewer).
      if (!isNullMoveSan(main.san)) {
        if (isWhite) {
          appendNumber(moveNumber, true, depth);
        } else if (isFirstMove || renumber) {
          appendNumber(moveNumber, false, depth);
        }
        appendMove(main, mainPath, depth);
      }

      var interrupted = appendAnnotations(main, mainPath, depth);

      if (siblings.length > 1) {
        interrupted = true;
        final parenStyle = PgnTextStyles.moveNumberAt(depth + 1);
        for (int i = 1; i < siblings.length; i++) {
          spans.add(TextSpan(text: '(', style: parenStyle));

          final variant = siblings[i];
          final variantPath = parentPath.child(i);

          if (!isNullMoveSan(variant.san)) {
            appendNumber(moveNumber, isWhite, depth + 1);
            appendMove(variant, variantPath, depth + 1);
          }

          final variantInterrupted = appendAnnotations(
            variant,
            variantPath,
            depth + 1,
          );

          appendSiblings(
            variant.children,
            isWhite ? moveNumber : moveNumber + 1,
            !isWhite,
            depth + 1,
            renumber: variantInterrupted,
            parentPath: variantPath,
          );

          trimSeparator();
          spans.add(TextSpan(text: ') ', style: parenStyle));
        }
      }

      appendSiblings(
        main.children,
        isWhite ? moveNumber : moveNumber + 1,
        !isWhite,
        depth,
        renumber: interrupted,
        parentPath: mainPath,
      );
    }

    appendSiblings(
      widget.tree.roots,
      startMoveNumber,
      startIsWhite,
      0,
      isFirstMove: true,
      parentPath: TreePath.empty,
    );
    flushSpans();

    if (canCache) {
      _cachedMoveWidgets = rows;
      _cachedTree = widget.tree;
      _cachedVersion = widget.tree.version;
    }

    return rows;
  }

  /// Inline flag marking where the puzzle segment of the line starts/ends.
  InlineSpan _markerSpan({required bool start}) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.only(left: 1, right: 1),
        child: Tooltip(
          message: start
              ? 'Puzzle starts here — training quizzes from this move'
              : 'Puzzle ends here — training stops after this move',
          child: Icon(
            start ? Icons.flag : Icons.sports_score,
            size: 13,
            color: AppColors.accent,
          ),
        ),
      ),
    );
  }

  /// Viewer-style inline editor shown in the move flow while a comment is
  /// being edited (right-click a move → Add/Edit Comment).
  Widget _buildInlineCommentEditor(MoveNode node, TreePath path) {
    return PgnCommentEditor(
      initialText: commentProse(node.comment ?? ''),
      onSave: (text) =>
          _saveInlineComment(path, mergeCommentProse(node.comment ?? '', text)),
      onCancel: () => setState(() => _editingCommentPath = null),
    );
  }

  /// Whether [nodePath] is on the path from root to [_contextMenuPath].
  bool _isOnContextPath(TreePath nodePath) {
    if (!_contextMenuOpen || _contextMenuPath == null) return false;
    final ctx = _contextMenuPath!;
    if (nodePath.length > ctx.length) return false;
    final nodeList = nodePath.toList();
    final ctxList = ctx.toList();
    for (int i = 0; i < nodeList.length; i++) {
      if (nodeList[i] != ctxList[i]) return false;
    }
    return true;
  }

  /// One move chip, repainted by [_selection] alone: the paragraph it sits
  /// in is cached across cursor moves, so selection has to arrive through a
  /// listener rather than through a rebuild — and only the two chips whose
  /// selected state actually flipped rebuild, not every chip on the page.
  Widget _buildSingleMoveWidget(MoveNode node, TreePath nodePath, int depth) {
    final isOnCtxPath = _isOnContextPath(nodePath);
    final nagSuffix = qualityNagSuffix(node.nags);
    return _SelectionAwareChip(
      selection: _selection,
      path: nodePath,
      builder: (isSelected) => _moveChip(
        node,
        nodePath,
        depth,
        nagSuffix: nagSuffix,
        isSelected: isSelected,
        isOnCtxPath: isOnCtxPath,
      ),
    );
  }

  Widget _moveChip(
    MoveNode node,
    TreePath nodePath,
    int depth, {
    required String nagSuffix,
    required bool isSelected,
    required bool isOnCtxPath,
  }) {
    Color? bgColor;
    Color borderColor = Colors.transparent;

    if (isSelected) {
      bgColor = AppColors.pgnMoveCurrentBg;
      borderColor = AppColors.pgnMoveCurrent;
    } else if (isOnCtxPath) {
      bgColor = AppColors.pgnMoveCurrentBg.withValues(alpha: 0.35);
    }

    // Depth carries the type treatment (semibold mainline, receding
    // sidelines); selection changes ink only — the pill marks the current
    // move, and a weight change here would reflow the wrapped movetext.
    final base = PgnTextStyles.moveAt(depth);
    final sanStyle = isSelected
        ? base.copyWith(color: AppColors.pgnMoveCurrentFg)
        : base;
    // No per-move underline: every move here is tappable, so a link underline
    // on each one is noise. The glyph suffix renders in exactly the same style
    // as the SAN ("Nf3!?" is one piece of text) — both match the PGN viewer.
    return MoveChip(
      san: node.san,
      nagSuffix: nagSuffix,
      sanStyle: sanStyle,
      nagStyle: sanStyle,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(3),
        // Always reserve the 1px border so selecting a move never resizes
        // it (which would reflow the wrapped move list) — same trick as the
        // PGN viewer.
        border: Border.all(color: borderColor, width: 1),
      ),
      onTap: () => _jumpTo(nodePath),
      onSecondaryTapDown: (d) => _showContextMenu(nodePath, d.globalPosition),
    );
  }
}

/// Rebuilds its chip only when "is [path] the selected move?" changes.
///
/// A plain [ValueListenableBuilder] on the cursor would rebuild every chip
/// in the movetext on every cursor move; this one compares the answer that
/// matters to this chip and stays put when it did not change, so stepping
/// through a line repaints exactly two chips.
class _SelectionAwareChip extends StatefulWidget {
  const _SelectionAwareChip({
    required this.selection,
    required this.path,
    required this.builder,
  });

  final ValueListenable<TreePath> selection;
  final TreePath path;
  final Widget Function(bool isSelected) builder;

  @override
  State<_SelectionAwareChip> createState() => _SelectionAwareChipState();
}

class _SelectionAwareChipState extends State<_SelectionAwareChip> {
  late bool _selected = widget.selection.value == widget.path;

  @override
  void initState() {
    super.initState();
    widget.selection.addListener(_onSelectionChanged);
  }

  @override
  void didUpdateWidget(_SelectionAwareChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.selection, widget.selection)) {
      oldWidget.selection.removeListener(_onSelectionChanged);
      widget.selection.addListener(_onSelectionChanged);
    }
    _selected = widget.selection.value == widget.path;
  }

  @override
  void dispose() {
    widget.selection.removeListener(_onSelectionChanged);
    super.dispose();
  }

  void _onSelectionChanged() {
    final selected = widget.selection.value == widget.path;
    if (selected == _selected) return;
    setState(() => _selected = selected);
  }

  @override
  Widget build(BuildContext context) => widget.builder(_selected);
}

class _PopupMenuRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _PopupMenuRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
