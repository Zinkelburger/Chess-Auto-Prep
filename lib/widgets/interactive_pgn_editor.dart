/// Interactive PGN editor widget for repertoire building.
///
/// Pure view: receives a [MoveTree] + [TreePath] from the controller and
/// fires callbacks for user actions.  No internal move state.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/utils/app_messages.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'pgn/comment_editor.dart';
import 'pgn/comment_prose_spans.dart';
import 'pgn/pgn_annotation_panel.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';

class InteractivePgnEditor extends StatefulWidget {
  /// The move tree to display (owned by controller).
  final MoveTree tree;

  /// Current cursor path (owned by controller).
  final TreePath currentPath;

  /// Jump the cursor to a different path (click on a move).
  final ValueChanged<TreePath>? onJump;

  /// Called when the user edits a comment.
  final void Function(TreePath path, String? comment)? onCommentChanged;

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

  final String? currentRepertoireName;
  final String? repertoireColor;

  /// Optional trap index (currently unused; kept for API compatibility).
  final TrapIndexService? trapIndex;

  /// Optional board preview on trap dot hover.
  final BoardPreviewController? boardPreview;

  /// Read-only header shown instead of the title field for ephemeral lines
  /// (e.g. "Trap #45 · Sicilian Defense").
  final String? ephemeralTitle;

  const InteractivePgnEditor({
    super.key,
    required this.tree,
    required this.currentPath,
    this.onJump,
    this.onCommentChanged,
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
    this.currentRepertoireName,
    this.repertoireColor,
    this.trapIndex,
    this.boardPreview,
    this.ephemeralTitle,
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

  List<Widget>? _cachedMoveWidgets;
  MoveTree? _cachedTree;
  TreePath? _cachedPath;

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
  }

  @override
  void dispose() {
    _titleController.dispose();
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
    // The tree was mutated in place, so the identity-based widget cache
    // would keep rendering the old comment.
    _cachedMoveWidgets = null;
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
    _cachedMoveWidgets = null;
    _scheduleAutoSave();
    if (mounted) setState(() {});
  }

  void _togglePanelNag(TreePath path, int nagId) {
    final node = widget.tree.nodeAt(path);
    if (node == null) return;
    final nags = List<int>.of(node.nags ?? const []);
    if (nags.contains(nagId)) {
      nags.remove(nagId);
    } else {
      // Move NAGs ($1–$6) are mutually exclusive.
      nags.removeWhere((n) => n >= 1 && n <= 6);
      nags.add(nagId);
    }
    node.nags = nags.isEmpty ? null : nags;
    widget.onDirty?.call();
    _cachedMoveWidgets = null;
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

    showMenu<String>(
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
        const PopupMenuItem(
          value: 'duplicate',
          child: _PopupMenuRow(icon: Icons.copy_all, text: 'Duplicate Line'),
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
    ).then((value) {
      setState(() => _contextMenuOpen = false);
      if (value == null) return;
      switch (value) {
        case 'comment':
          _startEditingComment(path);
          break;
        case 'promote':
          _promoteVariation();
          break;
        case 'mainline':
          _makeMainLine();
          break;
        case 'duplicate':
          _duplicateLine();
          break;
        case 'copy':
          _copyPgnFromHere();
          break;
        case 'viewlines':
          widget.onViewInLines?.call();
          break;
        case 'delete':
          _deleteFromHere();
          break;
      }
    });
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
                  color: AppColors.surfaceContainer,
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
                      Divider(height: 1, color: Colors.grey[800]),
                      const SizedBox(height: 4),
                    ] else if (_showTitleField) ...[
                      Row(
                        children: [
                          Icon(
                            Icons.drive_file_rename_outline,
                            size: 15,
                            color: Colors.grey[500],
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: TextField(
                              controller: _titleController,
                              decoration: InputDecoration(
                                hintText: 'Line title',
                                hintStyle: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                              ),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey[200],
                              ),
                              onChanged: (_) {
                                widget.onDirty?.call();
                                _scheduleAutoSave();
                              },
                            ),
                          ),
                        ],
                      ),
                      Divider(height: 1, color: Colors.grey[800]),
                      const SizedBox(height: 4),
                    ],
                    Expanded(
                      child: SingleChildScrollView(child: _buildMovesDisplay()),
                    ),
                  ],
                ),
              ),
            ),
            if (_showTitleField) _buildAnnotationPanel(),
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
    return PgnAnnotationPanel(
      targetKey: node == null ? null : 'n${node.id}',
      moveLabel: node == null ? '' : _moveLabelFor(path, node),
      nags: node?.nags ?? const [],
      comment: node?.comment ?? '',
      onToggleNag: (nagId) => _togglePanelNag(path, nagId),
      onCommentChanged: (text) => _commitPanelComment(path, text),
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

    return Wrap(
      spacing: 2,
      runSpacing: 4,
      children: _buildMoveWidgets(
        widget.tree.roots,
        startMoveNumber,
        startIsWhite,
        isFirstMove: true,
        parentPath: TreePath.empty,
        positionBefore: _startingPosition(),
      ),
    );
  }

  Position _startingPosition() {
    try {
      return widget.tree.startingFen != kStandardStartFen
          ? Chess.fromSetup(Setup.parseFen(widget.tree.startingFen))
          : Chess.initial;
    } catch (_) {
      return Chess.initial;
    }
  }

  /// A monospace move-number label (e.g. "12. " or "12... ") for the move list.
  Widget _moveNumberLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.pgnMoveNumber,
        fontFamily: 'monospace',
        fontSize: 14,
      ),
    );
  }

  List<Widget> _buildMoveWidgets(
    List<MoveNode> siblings,
    int moveNumber,
    bool isWhite, {
    bool isFirstMove = false,
    required TreePath parentPath,
    required Position positionBefore,
  }) {
    if (parentPath.isEmpty &&
        isFirstMove &&
        !_contextMenuOpen &&
        _editingCommentPath == null) {
      if (_cachedMoveWidgets != null &&
          identical(widget.tree, _cachedTree) &&
          widget.currentPath == _cachedPath) {
        return _cachedMoveWidgets!;
      }
    }

    final widgets = <Widget>[];
    if (siblings.isEmpty) return widgets;

    final main = siblings[0];
    final mainPath = parentPath.child(0);
    final mainMove = main.san == '--'
        ? null
        : positionBefore.parseSan(main.san);
    Position positionAfterMain = positionBefore;
    if (mainMove != null) {
      positionAfterMain = positionBefore.play(mainMove);
    }

    // Null moves ('--') anchor comments to a position; show the comment but
    // never the SAN itself (matches the PGN viewer).
    if (main.san != '--') {
      if (isWhite) {
        widgets.add(_moveNumberLabel('$moveNumber. '));
      } else if (isFirstMove) {
        widgets.add(_moveNumberLabel('$moveNumber... '));
      }

      widgets.add(_buildSingleMoveWidget(main, mainPath));
    }

    if (_editingCommentPath == mainPath) {
      widgets.add(_buildInlineCommentEditor(main, mainPath));
    } else if (main.comment != null && main.comment!.isNotEmpty) {
      widgets.add(_buildInlineComment(main.comment!));
    }

    if (siblings.length > 1) {
      for (int i = 1; i < siblings.length; i++) {
        widgets.add(
          const Text(
            ' ( ',
            style: TextStyle(
              color: AppColors.pgnVariation,
              fontFamily: 'monospace',
              fontSize: 14,
            ),
          ),
        );

        final variant = siblings[i];
        final variantPath = parentPath.child(i);
        final variantMove = variant.san == '--'
            ? null
            : positionBefore.parseSan(variant.san);
        Position positionAfterVariant = positionBefore;
        if (variantMove != null) {
          positionAfterVariant = positionBefore.play(variantMove);
        }

        if (variant.san != '--') {
          if (isWhite) {
            widgets.add(_moveNumberLabel('$moveNumber. '));
          } else {
            widgets.add(_moveNumberLabel('$moveNumber... '));
          }

          widgets.add(_buildSingleMoveWidget(variant, variantPath));
        }

        if (_editingCommentPath == variantPath) {
          widgets.add(_buildInlineCommentEditor(variant, variantPath));
        } else if (variant.comment != null && variant.comment!.isNotEmpty) {
          widgets.add(_buildInlineComment(variant.comment!));
        }

        widgets.addAll(
          _buildMoveWidgets(
            variant.children,
            isWhite ? moveNumber : moveNumber + 1,
            !isWhite,
            parentPath: variantPath,
            positionBefore: positionAfterVariant,
          ),
        );

        widgets.add(
          const Text(
            ' ) ',
            style: TextStyle(
              color: AppColors.pgnVariation,
              fontFamily: 'monospace',
              fontSize: 14,
            ),
          ),
        );
      }
    }

    widgets.addAll(
      _buildMoveWidgets(
        main.children,
        isWhite ? moveNumber : moveNumber + 1,
        !isWhite,
        parentPath: mainPath,
        positionBefore: positionAfterMain,
      ),
    );

    if (parentPath.isEmpty &&
        isFirstMove &&
        !_contextMenuOpen &&
        _editingCommentPath == null) {
      _cachedMoveWidgets = widgets;
      _cachedTree = widget.tree;
      _cachedPath = widget.currentPath;
    }

    return widgets;
  }

  Widget _buildInlineComment(String comment) {
    final spans = commentProseSpans(comment);
    if (spans.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 2),
      child: Text.rich(TextSpan(children: spans)),
    );
  }

  /// Viewer-style inline editor shown in the move flow while a comment is
  /// being edited (right-click a move → Add/Edit Comment).
  Widget _buildInlineCommentEditor(MoveNode node, TreePath path) {
    return PgnCommentEditor(
      initialText: node.comment ?? '',
      onSave: (text) => _saveInlineComment(path, text),
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

  Widget _buildSingleMoveWidget(MoveNode node, TreePath nodePath) {
    final isSelected = widget.currentPath == nodePath;
    final isOnCtxPath = _isOnContextPath(nodePath);

    late final Color textColor;
    Color? bgColor;
    Color borderColor = Colors.transparent;
    TextDecoration decoration = TextDecoration.none;

    if (isSelected) {
      textColor = AppColors.pgnMoveCurrentFg;
      bgColor = AppColors.pgnMoveCurrentBg;
      borderColor = AppColors.pgnMoveCurrent;
    } else if (isOnCtxPath) {
      textColor = Colors.white70;
      bgColor = Colors.blueGrey.withAlpha(60);
    } else {
      textColor = AppColors.pgnMove;
      decoration = TextDecoration.underline;
    }

    return GestureDetector(
      onTap: () => _jumpTo(nodePath),
      onSecondaryTapDown: (d) => _showContextMenu(nodePath, d.globalPosition),
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(3),
          // Always reserve the 1px border so selecting a move never resizes
          // it (which would reflow the wrapped move list) — same trick as the
          // PGN viewer.
          border: Border.all(color: borderColor, width: 1),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              node.san,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                color: textColor,
                fontWeight: FontWeight.normal,
                decoration: decoration,
                decorationColor: AppColors.onSurfaceDim.withValues(alpha: 0.45),
                decorationStyle: TextDecorationStyle.dotted,
              ),
            ),
          ],
        ),
      ),
    );
  }
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
