/// Interactive PGN editor widget for repertoire building.
///
/// Pure view: receives a [MoveTreeView] + [TreePath] from the controller and
/// fires callbacks for user actions.  No internal move state.
library;

import 'dart:async';

import '../features/documents/models/move_text_layout.dart';
import '../features/documents/widgets/move_text_viewport.dart';

import 'package:chess_auto_prep/utils/pgn_nags.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/pgn_text_styles.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import '../chess_core/moves/move_tree_view.dart';
import '../chess_core/moves/move_tree_snapshot.dart';
import 'package:chess_auto_prep/chess_core/pgn/move_text_writer.dart';
import 'package:chess_auto_prep/utils/app_messages.dart';
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart'
    show commentProse, mergeCommentProse;
import 'package:chess_auto_prep/utils/training_markers.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart'
    show MoveChip, PgnMoveDecorations;
import '../models/pgn_deletion_summary.dart';
import '../design_system/components/confirm_dialog.dart';
import 'pgn/comment_editor.dart';
import 'pgn/pgn_annotation_panel.dart';

class InteractivePgnEditor extends StatefulWidget {
  /// The move tree to display (owned by controller).
  final MoveTreeView tree;

  /// Read the owner's latest revision synchronously after a mutation callback.
  /// Autosave captures it before a widget rebuild or chapter switch can occur.
  /// The supplier must remain scoped to the displayed editing session.
  final MoveTreeView Function()? snapshotForSave;

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

  /// Exposes the pending debounce to hosts that must save before reading a
  /// replacement chapter. Null clears the registration after a flush.
  final ValueChanged<VoidCallback?>? onPendingAutoSaveChanged;

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
    this.snapshotForSave,
    this.onJump,
    this.onCommentChanged,
    this.onToggleNag,
    this.onDelete,
    this.onPromote,
    this.onMakeMainLine,
    this.onLineEdited,
    this.onAutoSave,
    this.onPendingAutoSaveChanged,
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
  final _selectedMoveKey = GlobalKey();
  TreePath? _contextMenuPath;
  bool _contextMenuOpen = false;

  /// Move whose comment is being edited inline (viewer-style editor shown in
  /// the move flow), or null.
  TreePath? _editingCommentPath;
  String? _inlineCommentDraft;

  Timer? _autoSaveTimer;
  VoidCallback? _pendingAutoSave;
  static const _autoSaveDelay = Duration(seconds: 2);

  // Cache only visible/recent rows. The pure index contains no widget trees,
  // and linked addresses avoid copying every ancestor path during indexing.
  MoveTextLayout? _layout;
  final _commentCache = MoveTextCommentCache();
  MoveTreeView? _layoutTree;
  int _layoutVersion = -1;
  int? _layoutEditingNode;
  (bool, TreePath?)? _rowContext;
  final _rowWidgets = <Object, Widget>{};
  static const _rowCacheLimit = 96;

  /// The cursor, for the chips.  Updated in [didUpdateWidget] so the two
  /// chips whose state changed repaint without the paragraph rebuilding.
  late final ValueNotifier<int?> _selection = ValueNotifier(
    widget.tree.nodeAt(widget.currentPath)?.id,
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
    if (widget.tree.identity != oldWidget.tree.identity) {
      _flushAutoSave();
      _editingCommentPath = null;
    } else if (_editingCommentPath != null &&
        oldWidget.tree.nodeAt(_editingCommentPath!)?.id !=
            widget.tree.nodeAt(_editingCommentPath!)?.id) {
      _editingCommentPath = null;
    }
    _selection.value = widget.tree.nodeAt(widget.currentPath)?.id;
  }

  @override
  void reassemble() {
    super.reassemble();
    // Hot reload must pick up layout changes even when the model is unchanged.
    // Cursor navigation still keeps the cached paragraphs in normal builds.
    _layout = null;
    _rowWidgets.clear();
  }

  @override
  void dispose() {
    _flushAutoSave();
    _titleController.dispose();
    _selection.dispose();
    _autoSaveTimer?.cancel();
    super.dispose();
  }

  // ── Callbacks into controller ─────────────────────────────────────

  void _jumpTo(TreePath path) {
    if (!mounted) return;
    widget.onJump?.call(path);
  }

  void _startEditingComment(TreePath path) {
    if (!mounted) return;
    _jumpTo(path);
    if (!mounted) return;
    setState(() {
      _editingCommentPath = path;
      _inlineCommentDraft = commentProse(widget.tree.commentAt(path) ?? '');
    });
  }

  void _saveInlineComment(TreePath path, String comment) {
    if (!mounted) return;
    final trimmed = comment.trim();
    widget.onCommentChanged?.call(path, trimmed.isEmpty ? null : trimmed);
    widget.onDirty?.call();
    _scheduleAutoSave();
    if (!mounted) return;
    setState(() => _editingCommentPath = null);
  }

  /// Comment committed from the persistent bottom annotation panel.
  ///
  /// The field shows prose only; the comment's `[%cal]` shapes, `[%eval]`
  /// readouts and quiz markers are re-attached here, so typing a note can
  /// never delete them.  The empty path is the chapter's introduction
  /// ([MoveTree.rootComment]).
  void _commitPanelComment(TreePath path, String prose) {
    if (path.isNotEmpty && widget.tree.nodeAt(path) == null) return;
    final raw = widget.tree.commentAt(path) ?? '';
    final merged = mergeCommentProse(raw, prose);
    final normalized = merged.isEmpty ? null : merged;
    if (raw == merged) return;
    widget.onCommentChanged?.call(path, normalized);
    widget.onDirty?.call();
    _scheduleAutoSave();
    if (mounted) setState(() {});
  }

  void _togglePanelNag(TreePath path, int nagId) {
    if (path.isEmpty) return; // the start position takes no glyph
    final onToggle = widget.onToggleNag;
    if (onToggle == null) return;
    onToggle(path, nagId);
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

  Future<void> _deleteFromHere() async {
    final path = _contextMenuPath;
    if (path == null || widget.onDelete == null) return;
    final tree = widget.tree;
    final node = tree.nodeAt(path);
    if (node == null) return;
    final version = tree.version;
    final summary = PgnDeletionSummary.nodes([node]);
    final confirmed = await confirmAction(
      context,
      title: 'Delete ${summary.description}?',
      message:
          'This removes the move and all continuations from here, '
          'including their annotations.',
      confirmLabel: 'Delete',
    );
    if (!mounted ||
        !confirmed ||
        !identical(widget.tree, tree) ||
        tree.version != version) {
      return;
    }
    widget.onDelete?.call(path);
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
    final (number, white) = MoveTree.moveNumberFromFen(
      widget.tree.fenAt(_contextMenuPath!.parent),
    );
    final text = writeMoveText(
      roots: [node],
      startMoveNumber: number,
      startIsWhite: white,
    );
    widget.onCopyToClipboard?.call(text, AppMessages.pgnCopied);
  }

  void _scheduleAutoSave() {
    if (!widget.isEditingExistingLine) return;
    _autoSaveTimer?.cancel();
    // Capture both the content and destination now. Navigation may replace
    // the widget's tree and callbacks before this debounce expires.
    final pgn = _buildFullPgnForSave();
    final onSave = widget.onAutoSave ?? widget.onLineEdited;
    _pendingAutoSave = onSave == null ? null : () => onSave(pgn);
    _autoSaveTimer = Timer(_autoSaveDelay, _flushAutoSave);
    widget.onPendingAutoSaveChanged?.call(_flushAutoSave);
  }

  void _flushAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    final save = _pendingAutoSave;
    _pendingAutoSave = null;
    widget.onPendingAutoSaveChanged?.call(null);
    save?.call();
  }

  String _buildFullPgnForSave() {
    final typed = _titleController.text.trim();
    final title = typed.isNotEmpty
        ? typed
        : (widget.lineTitle?.trim().isNotEmpty ?? false)
        ? widget.lineTitle!.trim()
        : 'Repertoire Line';
    final tree = widget.snapshotForSave?.call() ?? widget.tree;
    return tree.toPgn(
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
    if (!mounted) return;
    unawaited(_runContextMenu(path, globalPosition));
  }

  Future<void> _runContextMenu(TreePath path, Offset globalPosition) async {
    _contextMenuPath = path;
    final menuTree = widget.tree;
    final menuVersion = menuTree.version;
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
        // Quiz markers: where the trainer starts asking for moves and where
        // it stops.  Moves before the start auto-play as the intro.
        if (widget.onCommentChanged != null) ...[
          PopupMenuItem(
            value: 'puzzle_start',
            child: _PopupMenuRow(
              icon: Icons.flag,
              text: hasPuzzleStart(node?.comment)
                  ? 'Unmark Quiz Start'
                  : 'Start Quiz From This Move',
            ),
          ),
          PopupMenuItem(
            value: 'puzzle_end',
            child: _PopupMenuRow(
              icon: Icons.sports_score,
              text: hasPuzzleEnd(node?.comment)
                  ? 'Unmark Quiz End'
                  : 'End Quiz After This Move',
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
    if (value == null ||
        widget.tree.identity != menuTree.identity ||
        widget.tree.version != menuVersion) {
      return;
    }
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
        await _deleteFromHere();
    }
  }

  // ── Build ─────────────────────────────────────────────────────────

  /// The title field only makes sense where the editor persists whole lines
  /// (repertoire builder). Hosts with their own naming UI (study chapters)
  /// pass no save callbacks and get a clean movetext-only surface.
  bool get _showTitleField =>
      widget.isEditingExistingLine ||
      widget.onLineEdited != null ||
      widget.onAutoSave != null;

  @override
  Widget build(BuildContext context) {
    // Stretch: the movetext box fills the pane it is given.  Left to size
    // itself it was exactly as wide as its longest row, which put a lone
    // "1. e4" in a black strip with empty pane either side.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.pgnSurface,
                borderRadius: BorderRadius.circular(8),
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
                              contentPadding: EdgeInsets.symmetric(vertical: 4),
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
                  Expanded(child: _buildMovesDisplay()),
                ],
              ),
            ),
          ),
          if (_showTitleField || widget.showAnnotationPanel)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * .55,
              ),
              child: SingleChildScrollView(child: _buildAnnotationPanel()),
            ),
        ],
      ),
    );
  }

  /// Persistent annotation strip pinned below the move list: the move the
  /// cursor sits on is always editable here, no right-click needed.  At the
  /// start position it edits the chapter's introduction instead.
  Widget _buildAnnotationPanel() {
    final path = widget.currentPath;
    final node = path.isEmpty ? null : widget.tree.nodeAt(path);
    final atRoot = path.isEmpty;
    final raw = widget.tree.commentAt(path) ?? '';
    return PgnAnnotationPanel(
      compact: _showTitleField,
      key: ObjectKey(widget.tree.identity),
      // Tree mutations are cheap and the host already debounces disk saves.
      // Commit before a chapter switch changes the controller's target tree.
      commentDebounce: Duration.zero,
      targetKey: atRoot ? 'root' : (node == null ? null : 'n${node.id}'),
      moveLabel: atRoot
          ? 'the start position'
          : (node == null ? '' : _moveLabelFor(path, node)),
      nags: node?.nags ?? const [],
      glyphsEnabled: !atRoot && widget.onToggleNag != null,
      comment: commentProse(raw),
      onToggleNag: (nagId) => _togglePanelNag(path, nagId),
      onCommentChanged: (text) => _commitPanelComment(path, text),
    );
  }

  String _moveLabelFor(TreePath path, MoveNodeView node) {
    final (startMoveNumber, startIsWhite) = MoveTree.moveNumberFromFen(
      widget.tree.startingFen,
    );
    final ply = path.length - 1;
    final isWhiteMove = startIsWhite ? ply.isEven : ply.isOdd;
    final moveNumber = startMoveNumber + ((startIsWhite ? ply : ply + 1) ~/ 2);
    return '$moveNumber${isWhiteMove ? '.' : '...'} ${node.san}';
  }

  Widget _buildMovesDisplay() {
    if (widget.tree.isEmpty && widget.tree.rootComment == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Text(
          'Play a move or select a saved line.',
          style: AppTextStyles.muted,
        ),
      );
    }

    final editingNode = _editingCommentPath == null
        ? null
        : widget.tree.nodeAt(_editingCommentPath!)?.id;
    if (_layout == null ||
        !identical(_layoutTree, widget.tree) ||
        _layoutVersion != widget.tree.version ||
        _layoutEditingNode != editingNode) {
      final tree = widget.tree;
      final revised =
          _layoutEditingNode == editingNode && tree is MoveTreeSnapshot
          ? _layout?.reviseAnnotations(tree, comments: _commentCache)
          : null;
      _layout =
          revised ??
          MoveTextLayout.capture(
            tree,
            editingNodeId: editingNode,
            comments: _commentCache,
          );
      _layoutTree = widget.tree;
      _layoutVersion = widget.tree.version;
      _layoutEditingNode = editingNode;
      _rowWidgets.clear();
    }
    final rowContext = (_contextMenuOpen, _contextMenuPath);
    if (_rowContext != rowContext) {
      _rowContext = rowContext;
      _rowWidgets.clear();
    }
    return MoveTextViewport(
      layout: _layout!,
      selectionKey: _selectedMoveKey,
      session: widget.tree.identity,
      selectedNodeId: widget.tree.nodeAt(widget.currentPath)?.id,
      rowBuilder: _buildMoveRow,
    );
  }

  Widget _buildMoveRow(MoveTextRow row) {
    final cached = _rowWidgets.remove(row.key);
    if (cached != null) {
      _rowWidgets[row.key] = cached;
      return cached;
    }
    final Widget child;
    switch (row) {
      case MoveTextRun():
        final spans = <InlineSpan>[];
        for (final move in row.moves) {
          if (move.showNumber) {
            spans.add(
              TextSpan(
                text: '${move.number}${move.white ? '.' : '...'}\u00a0',
                style: PgnTextStyles.moveNumberAt(row.depth),
              ),
            );
          }
          if (hasPuzzleStart(move.node.comment)) {
            spans.add(_markerSpan(start: true));
          }
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _buildSingleMoveWidget(move.node, move.address, row.depth),
            ),
          );
          if (hasPuzzleEnd(move.node.comment)) {
            spans.add(_markerSpan(start: false));
          }
          spans.add(const TextSpan(text: ' '));
        }
        child = Text.rich(
          TextSpan(style: PgnTextStyles.rowRootAt(row.depth), children: spans),
        );
      case MoveTextComment():
        child = Text.rich(
          TextSpan(
            text: '${row.text} ',
            style: PgnTextStyles.commentAt(row.depth),
          ),
        );
      case MoveTextInlineEditor():
        child = _buildInlineCommentEditor(row.node, row.address.toPath());
    }
    final result = Padding(
      padding: EdgeInsets.only(
        left:
            PgnTextStyles.depthIndent *
            row.depth.clamp(0, PgnTextStyles.maxStyledDepth),
        top: row is MoveTextComment ? 4 : 3,
        bottom: row is MoveTextComment ? 4 : 3,
      ),
      child: SizedBox(width: double.infinity, child: child),
    );
    // An inline editor must receive the latest retained draft after eviction.
    if (row is! MoveTextInlineEditor) _rowWidgets[row.key] = result;
    if (_rowWidgets.length > _rowCacheLimit) {
      _rowWidgets.remove(_rowWidgets.keys.first);
    }
    return result;
  }

  /// Inline flag marking where the puzzle segment of the line starts/ends.
  InlineSpan _markerSpan({required bool start}) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.only(left: 1, right: 1),
        child: Tooltip(
          message: start
              ? 'Quiz starts here: training auto-plays the moves before '
                    'this one and asks for this one'
              : 'Quiz ends here: training stops after this move',
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
  Widget _buildInlineCommentEditor(MoveNodeView node, TreePath path) {
    return PgnCommentEditor(
      initialText: _inlineCommentDraft ?? commentProse(node.comment ?? ''),
      onChanged: (text) => _inlineCommentDraft = text,
      onSave: (text) =>
          _saveInlineComment(path, mergeCommentProse(node.comment ?? '', text)),
      onCancel: () {
        if (!mounted) return;
        setState(() => _editingCommentPath = null);
      },
    );
  }

  /// Only a context-menu gesture needs ancestor highlighting. Walk linked
  /// indices without allocating a full path for every rendered chip.
  bool _isOnContextPath(MoveTextAddress address) {
    final target = _contextMenuPath;
    if (!_contextMenuOpen || target == null || address.length > target.length) {
      return false;
    }
    MoveTextAddress? cursor = address;
    while (cursor != null) {
      if (cursor.index != target[cursor.length - 1]) return false;
      cursor = cursor.parent;
    }
    return true;
  }

  /// One move chip, repainted by [_selection] alone: the paragraph it sits
  /// in is cached across cursor moves, so selection has to arrive through a
  /// listener rather than through a rebuild — and only the two chips whose
  /// selected state actually flipped rebuild, not every chip on the page.
  Widget _buildSingleMoveWidget(
    MoveNodeView node,
    MoveTextAddress nodePath,
    int depth,
  ) {
    final isOnCtxPath = _isOnContextPath(nodePath);
    final nagSuffix = allNagSuffix(node.nags);
    return _SelectionAwareChip(
      selection: _selection,
      nodeId: node.id,
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
    MoveNodeView node,
    MoveTextAddress nodePath,
    int depth, {
    required String nagSuffix,
    required bool isSelected,
    required bool isOnCtxPath,
  }) {
    // Moves keep the same size and weight across annotations and depth;
    // selection changes ink only, with a pill marking the current move.
    final base = PgnTextStyles.moveAt(depth, ephemeral: node.isEphemeral);
    final sanStyle = isSelected
        ? base.copyWith(color: AppColors.pgnMoveCurrentFg)
        : base;
    return KeyedSubtree(
      key: isSelected ? _selectedMoveKey : null,
      child: MoveChip(
        san: node.san,
        nagSuffix: nagSuffix,
        sanStyle: sanStyle,
        nagStyle: PgnTextStyles.nagAt(
          depth,
          moveStyle: sanStyle,
          nags: node.nags,
        ),
        decoration: PgnMoveDecorations.resolve(
          selected: isSelected,
          isEphemeral: node.isEphemeral,
          onContextPath: isOnCtxPath,
        ),
        hoverDecoration: PgnMoveDecorations.resolve(
          selected: isSelected,
          isEphemeral: node.isEphemeral,
          hovered: true,
        ),
        behavior: HitTestBehavior.opaque,
        onTap: () => _jumpTo(nodePath.toPath()),
        onSecondaryTapDown: (d) =>
            _showContextMenu(nodePath.toPath(), d.globalPosition),
      ),
    );
  }
}

/// Rebuilds its chip only when "is [nodeId] the selected move?" changes.
///
/// A plain [ValueListenableBuilder] on the cursor would rebuild every chip
/// in the movetext on every cursor move; this one compares the answer that
/// matters to this chip and stays put when it did not change, so stepping
/// through a line repaints exactly two chips.
class _SelectionAwareChip extends StatefulWidget {
  const _SelectionAwareChip({
    required this.selection,
    required this.nodeId,
    required this.builder,
  });

  final ValueListenable<int?> selection;
  final int nodeId;
  final Widget Function(bool isSelected) builder;

  @override
  State<_SelectionAwareChip> createState() => _SelectionAwareChipState();
}

class _SelectionAwareChipState extends State<_SelectionAwareChip> {
  late bool _selected = widget.selection.value == widget.nodeId;

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
    _selected = widget.selection.value == widget.nodeId;
  }

  @override
  void dispose() {
    widget.selection.removeListener(_onSelectionChanged);
    super.dispose();
  }

  void _onSelectionChanged() {
    if (!mounted) return;
    final selected = widget.selection.value == widget.nodeId;
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
        Flexible(child: Text(text, style: const TextStyle(fontSize: 12))),
      ],
    );
  }
}
