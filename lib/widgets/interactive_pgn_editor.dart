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
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart'
    show filterDisplayComment;
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/features/traps/widgets/trap_move_indicator.dart';

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

  final String? currentRepertoireName;
  final String? repertoireColor;

  /// Optional trap index for orange dot markers.
  final TrapIndexService? trapIndex;

  /// Optional board preview on trap dot hover.
  final BoardPreviewController? boardPreview;

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
    this.currentRepertoireName,
    this.repertoireColor,
    this.trapIndex,
    this.boardPreview,
  });

  @override
  State<InteractivePgnEditor> createState() => _InteractivePgnEditorState();
}

class _InteractivePgnEditorState extends State<InteractivePgnEditor> {
  final TextEditingController _commentController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final FocusNode _commentFocusNode = FocusNode();
  TreePath? _contextMenuPath;
  bool _contextMenuOpen = false;
  Timer? _autoSaveTimer;
  static const _autoSaveDelay = Duration(seconds: 2);

  List<Widget>? _cachedMoveWidgets;
  MoveTree? _cachedTree;
  TreePath? _cachedPath;

  @override
  void initState() {
    super.initState();
    _syncComment();
  }

  @override
  void didUpdateWidget(InteractivePgnEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentPath != oldWidget.currentPath) {
      _syncComment();
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    _titleController.dispose();
    _commentFocusNode.dispose();
    _autoSaveTimer?.cancel();
    super.dispose();
  }

  void _syncComment() {
    final node = widget.tree.nodeAt(widget.currentPath);
    _commentController.text = node?.comment ?? '';
  }

  // ── Callbacks into controller ─────────────────────────────────────

  void _jumpTo(TreePath path) => widget.onJump?.call(path);

  void _updateComment(String comment) {
    if (widget.currentPath.isEmpty) return;
    final trimmed = comment.isEmpty ? null : comment;
    widget.onCommentChanged?.call(widget.currentPath, trimmed);
    widget.onDirty?.call();
    _scheduleAutoSave();
  }

  void _deleteFromHere() {
    if (_contextMenuPath == null) return;
    widget.onDelete?.call(_contextMenuPath!);
  }

  void _focusCommentField() {
    if (_contextMenuPath != null) {
      _jumpTo(_contextMenuPath!);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _commentController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _commentController.text.length,
      );
      FocusScope.of(context).requestFocus(_commentFocusNode);
    });
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
    final subtree =
        MoveTree.fromMoves(fullMoves, startingFen: widget.tree.startingFen);
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
    final title = _titleController.text.trim().isNotEmpty
        ? _titleController.text.trim()
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

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );

    showMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem(
          enabled: false,
          height: 32,
          child: Text(moveName,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        ),
        const PopupMenuDivider(height: 1),
        const PopupMenuItem(
          value: 'comment',
          child: _PopupMenuRow(icon: Icons.comment, text: 'Add Comment'),
        ),
        if (!isOnMainline)
          const PopupMenuItem(
            value: 'promote',
            child: _PopupMenuRow(
                icon: Icons.arrow_upward, text: 'Promote Variation'),
          ),
        if (!isOnMainline)
          const PopupMenuItem(
            value: 'mainline',
            child: _PopupMenuRow(
                icon: Icons.vertical_align_top, text: 'Make Main Line'),
          ),
        const PopupMenuItem(
          value: 'duplicate',
          child: _PopupMenuRow(icon: Icons.copy_all, text: 'Duplicate Line'),
        ),
        const PopupMenuItem(
          value: 'copy',
          child: _PopupMenuRow(
              icon: Icons.content_copy, text: 'Copy PGN from Here'),
        ),
        if (widget.isEditingExistingLine && widget.onViewInLines != null)
          const PopupMenuItem(
            value: 'viewlines',
            child: _PopupMenuRow(icon: Icons.list_alt, text: 'View in Lines'),
          ),
        const PopupMenuDivider(height: 1),
        PopupMenuItem(
          value: 'delete',
          child: _PopupMenuRow(
              icon: Icons.delete_outline,
              text: 'Delete from Here',
              color: Colors.grey[400]),
        ),
      ],
    ).then((value) {
      setState(() => _contextMenuOpen = false);
      if (value == null) return;
      switch (value) {
        case 'comment':
          _focusCommentField();
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
                    TextField(
                      controller: _titleController,
                      decoration: InputDecoration(
                        hintText: 'Title',
                        hintStyle:
                            TextStyle(color: Colors.grey[600], fontSize: 12),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 2),
                      ),
                      style: TextStyle(fontSize: 12, color: Colors.grey[300]),
                    ),
                    Divider(height: 1, color: Colors.grey[800]),
                    const SizedBox(height: 4),
                    Expanded(
                      child: SingleChildScrollView(
                        child: _buildMovesDisplay(),
                      ),
                    ),
                    Divider(height: 1, color: Colors.grey[800]),
                    TextField(
                      controller: _commentController,
                      focusNode: _commentFocusNode,
                      decoration: InputDecoration(
                        hintText: 'Add comment',
                        hintStyle:
                            TextStyle(color: Colors.grey[600], fontSize: 12),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      ),
                      style: TextStyle(fontSize: 12, color: Colors.grey[300]),
                      onChanged: _updateComment,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMovesDisplay() {
    if (widget.tree.isEmpty) {
      return const SizedBox.shrink();
    }

    final (startMoveNumber, startIsWhite) =
        MoveTree.moveNumberFromFen(widget.tree.startingFen);

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

  List<Widget> _buildMoveWidgets(
    List<MoveNode> siblings,
    int moveNumber,
    bool isWhite, {
    bool isFirstMove = false,
    required TreePath parentPath,
    required Position positionBefore,
  }) {
    if (parentPath.isEmpty && isFirstMove && !_contextMenuOpen) {
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
    final mainMove =
        main.san == '--' ? null : positionBefore.parseSan(main.san);
    Position positionAfterMain = positionBefore;
    TrapLineInfo? mainTrap;
    if (mainMove != null) {
      positionAfterMain = positionBefore.play(mainMove);
      mainTrap = widget.trapIndex?.trapAtFen(positionAfterMain.fen);
    }

    if (isWhite) {
      widgets.add(Text('$moveNumber. ',
          style: const TextStyle(
            color: AppColors.pgnMoveNumber,
            fontFamily: 'monospace',
            fontSize: 13,
          )));
    } else if (isFirstMove) {
      widgets.add(Text('$moveNumber... ',
          style: const TextStyle(
            color: AppColors.pgnMoveNumber,
            fontFamily: 'monospace',
            fontSize: 13,
          )));
    }

    widgets.add(_buildSingleMoveWidget(
      main,
      mainPath,
      trap: mainTrap,
    ));

    if (main.comment != null && main.comment!.isNotEmpty) {
      widgets.add(_buildInlineComment(main.comment!));
    }

    if (siblings.length > 1) {
      for (int i = 1; i < siblings.length; i++) {
        widgets.add(const Text(' ( ',
            style: TextStyle(
              color: AppColors.pgnVariation,
              fontFamily: 'monospace',
              fontSize: 13,
            )));

        final variant = siblings[i];
        final variantPath = parentPath.child(i);
        final variantMove =
            variant.san == '--' ? null : positionBefore.parseSan(variant.san);
        Position positionAfterVariant = positionBefore;
        TrapLineInfo? variantTrap;
        if (variantMove != null) {
          positionAfterVariant = positionBefore.play(variantMove);
          variantTrap = widget.trapIndex?.trapAtFen(positionAfterVariant.fen);
        }

        if (isWhite) {
          widgets.add(Text('$moveNumber. ',
              style: const TextStyle(
                color: AppColors.pgnMoveNumber,
                fontFamily: 'monospace',
                fontSize: 13,
              )));
        } else {
          widgets.add(Text('$moveNumber... ',
              style: const TextStyle(
                color: AppColors.pgnMoveNumber,
                fontFamily: 'monospace',
                fontSize: 13,
              )));
        }

        widgets.add(_buildSingleMoveWidget(
          variant,
          variantPath,
          trap: variantTrap,
        ));

        if (variant.comment != null && variant.comment!.isNotEmpty) {
          widgets.add(_buildInlineComment(variant.comment!));
        }

        widgets.addAll(_buildMoveWidgets(
          variant.children,
          isWhite ? moveNumber : moveNumber + 1,
          !isWhite,
          parentPath: variantPath,
          positionBefore: positionAfterVariant,
        ));

        widgets.add(const Text(' ) ',
            style: TextStyle(
              color: AppColors.pgnVariation,
              fontFamily: 'monospace',
              fontSize: 13,
            )));
      }
    }

    widgets.addAll(_buildMoveWidgets(
      main.children,
      isWhite ? moveNumber : moveNumber + 1,
      !isWhite,
      parentPath: mainPath,
      positionBefore: positionAfterMain,
    ));

    if (parentPath.isEmpty && isFirstMove && !_contextMenuOpen) {
      _cachedMoveWidgets = widgets;
      _cachedTree = widget.tree;
      _cachedPath = widget.currentPath;
    }

    return widgets;
  }

  Widget _buildInlineComment(String comment) {
    final sanitized =
        filterDisplayComment(comment.replaceAll('{', '').replaceAll('}', ''));
    if (sanitized.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 2),
      child: Text(
        sanitized,
        style: const TextStyle(
          fontSize: 13,
          height: 1.35,
          color: AppColors.pgnComment,
        ),
      ),
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

  Widget _buildSingleMoveWidget(
    MoveNode node,
    TreePath nodePath, {
    TrapLineInfo? trap,
  }) {
    final isSelected = widget.currentPath == nodePath;
    final isOnCtxPath = _isOnContextPath(nodePath);

    late final Color textColor;
    Color? bgColor;
    FontWeight fontWeight = FontWeight.normal;
    TextDecoration decoration = TextDecoration.none;

    if (isSelected) {
      textColor = Colors.white;
      bgColor = AppColors.pgnMoveSelectedBg;
      fontWeight = FontWeight.w500;
    } else if (isOnCtxPath) {
      textColor = Colors.white70;
      bgColor = Colors.blueGrey.withAlpha(60);
      fontWeight = FontWeight.w500;
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
        ),
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              node.san,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: textColor,
                fontWeight: fontWeight,
                decoration: decoration,
                decorationColor: AppColors.onSurfaceDim.withValues(alpha: 0.45),
                decorationStyle: TextDecorationStyle.dotted,
              ),
            ),
            if (trap != null)
              TrapMoveIndicator(
                trap: trap,
                boardPreview: widget.boardPreview,
                previewFen: node.fen,
                ownerTag: this,
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
  final Color? color;

  const _PopupMenuRow({
    required this.icon,
    required this.text,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(text, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}
