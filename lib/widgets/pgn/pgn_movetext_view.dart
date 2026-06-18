/// Movetext rendering for the PGN viewer.
///
/// Renders the mainline + sideline variations + inline/prose comments as a
/// flowing `Wrap` of `RichText`, plus the edit-mode annotation toolbar and
/// inline comment editor. Extracted from `pgn_viewer_widget.dart` (WS-C / B2)
/// as a pure leaf view: it takes the move history, the per-ply variation tree,
/// the current navigation/edit state, and callbacks — it owns no state of its
/// own (the inline editor keeps its own [TextEditingController]).
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../models/move_tree.dart';
import '../../theme/app_colors.dart';
import '../../utils/pgn_comment_utils.dart'
    show
        filterDisplayComment,
        formatProseComment,
        NagInfo,
        kMoveNags,
        nagSymbol,
        nagColor;

class PgnMovetextView extends StatelessWidget {
  /// The parsed game (for game-level comments before any move).
  final PgnGame? game;

  /// Mainline moves in display order.
  final List<PgnNodeData> moveHistory;

  /// ply (0-based mainline index) -> root variation nodes branching there.
  final Map<int, List<MoveNode>> variationsByPly;

  /// 1-based index of the current mainline position (0 = start).
  final int mainLineIndex;

  /// Path into the current variation (empty = on the mainline).
  final List<MoveNode> analysisPath;

  /// Mainline index selected for annotation (edit mode), or null.
  final int? selectedMoveIndex;

  /// Mainline index whose comment is being edited inline, or null.
  final int? editingCommentIndex;

  /// Whether the viewer is in edit mode (annotation toolbar + context menu).
  final bool editMode;

  /// Whether comments can be edited (click a move to edit its comment).
  final bool canEditComments;

  final ValueChanged<int> onMainLineMoveClicked;
  final ValueChanged<int> onSelectMoveForAnnotation;
  final void Function(int moveIndex, Offset globalPosition) onShowMoveContextMenu;
  final ValueChanged<int> onStartEditingComment;
  final void Function(int moveIndex, int nagId) onToggleNag;
  final void Function(int moveIndex, String text) onSaveComment;
  final VoidCallback onCancelEditingComment;
  final VoidCallback onDismissAnnotation;
  final void Function(MoveNode node, int branchPly) onGoToAnalysisNode;

  /// Right-click action on an ephemeral analysis node (delete/clear menu).
  final void Function(int nodeId, Offset globalPosition)? onAnalysisNodeAction;

  const PgnMovetextView({
    super.key,
    required this.game,
    required this.moveHistory,
    required this.variationsByPly,
    required this.mainLineIndex,
    required this.analysisPath,
    required this.selectedMoveIndex,
    required this.editingCommentIndex,
    required this.editMode,
    required this.canEditComments,
    required this.onMainLineMoveClicked,
    required this.onSelectMoveForAnnotation,
    required this.onShowMoveContextMenu,
    required this.onStartEditingComment,
    required this.onToggleNag,
    required this.onSaveComment,
    required this.onCancelEditingComment,
    required this.onDismissAnnotation,
    required this.onGoToAnalysisNode,
    this.onAnalysisNodeAction,
  });

  static String _filterComment(String comment) => filterDisplayComment(comment);

  static String _rawComment(PgnNodeData moveData) {
    if (moveData.comments == null || moveData.comments!.isEmpty) return '';
    return moveData.comments!.first;
  }

  @override
  Widget build(BuildContext context) {
    if (moveHistory.isEmpty &&
        variationsByPly.isEmpty &&
        (game == null || game!.comments.isEmpty)) {
      return const SizedBox();
    }

    final children = <Widget>[];
    final spans = <InlineSpan>[];
    var moveNumber = 1;
    var isWhiteTurn = true;

    const baseStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 14,
      color: AppColors.pgnMove,
    );

    void flushSpans() {
      if (spans.isNotEmpty) {
        children.add(RichText(
          text: TextSpan(style: baseStyle, children: List.of(spans)),
        ));
        spans.clear();
      }
    }

    // Game-level comments (before any moves) — common in book PGNs
    if (game != null && game!.comments.isNotEmpty) {
      for (final comment in game!.comments) {
        final paragraphs = formatProseComment(comment);
        if (paragraphs.isNotEmpty) {
          children.add(_buildProseBlock(paragraphs));
        }
      }
    }

    // Variations at ply 0 (before any move)
    final varsAtZero = variationsByPly[0];
    if (varsAtZero != null && varsAtZero.isNotEmpty) {
      spans.addAll(_buildVariationSpansAtPly(0));
    }

    for (int i = 0; i < moveHistory.length; i++) {
      final moveData = moveHistory[i];
      final san = moveData.san;

      // Render startingComments (comments before the move)
      if (moveData.startingComments != null &&
          moveData.startingComments!.isNotEmpty) {
        for (final sc in moveData.startingComments!) {
          final paragraphs = formatProseComment(sc);
          if (paragraphs.isNotEmpty) {
            flushSpans();
            children.add(_buildProseBlock(paragraphs));
          }
        }
      }

      // Skip rendering null-move SAN but still show its comments
      if (san == '--') {
        if (moveData.comments != null && moveData.comments!.isNotEmpty) {
          final comment = _filterComment(moveData.comments!.first);
          if (comment.isNotEmpty) {
            final paragraphs = formatProseComment(moveData.comments!.first);
            if (paragraphs.isNotEmpty) {
              flushSpans();
              children.add(_buildProseBlock(paragraphs));
            } else {
              spans.add(_buildCommentSpan(comment));
            }
          }
        }
        if (!isWhiteTurn) moveNumber++;
        isWhiteTurn = !isWhiteTurn;
        continue;
      }

      if (isWhiteTurn) {
        spans.add(TextSpan(
          text: '$moveNumber. ',
          style: const TextStyle(
            color: AppColors.pgnMoveNumber,
            fontFamily: 'monospace',
          ),
        ));
      }

      final isCurrentMove = i == mainLineIndex - 1 && analysisPath.isEmpty;
      final hasBranch = variationsByPly.containsKey(i + 1);

      final inEditMode = editMode;
      final isSelected = inEditMode && selectedMoveIndex == i;

      // Determine move color: in edit mode, NAG color takes priority
      final moveNag = (inEditMode &&
              moveData.nags != null &&
              moveData.nags!.isNotEmpty)
          ? moveData.nags!.firstWhere((n) => n >= 1 && n <= 6, orElse: () => 0)
          : 0;
      final nagMoveColor = moveNag > 0 ? nagColor(moveNag) : null;

      final moveColor = isCurrentMove
          ? AppColors.pgnMoveCurrent
          : (nagMoveColor ??
              (hasBranch ? AppColors.lichessDb : AppColors.info));

      // Build SAN + NAG text
      final nagSuffix = (inEditMode &&
              moveData.nags != null &&
              moveData.nags!.isNotEmpty)
          ? moveData.nags!.where((n) => n >= 1 && n <= 6).map(nagSymbol).join()
          : '';

      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              onMainLineMoveClicked(i);
              if (inEditMode) onSelectMoveForAnnotation(i);
            },
            onSecondaryTapDown: inEditMode
                ? (details) => onShowMoveContextMenu(i, details.globalPosition)
                : (canEditComments ? (_) => onStartEditingComment(i) : null),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              decoration: BoxDecoration(
                color: isCurrentMove
                    ? AppColors.pgnMoveCurrentBg
                    : (isSelected
                        ? AppColors.pgnMoveCurrentBg.withValues(alpha: 0.5)
                        : null),
                borderRadius: BorderRadius.circular(3),
                border: isSelected
                    ? Border.all(
                        color: moveColor.withValues(alpha: 0.6), width: 1)
                    : null,
              ),
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: san,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      color: moveColor,
                      fontWeight:
                          isCurrentMove ? FontWeight.w500 : FontWeight.normal,
                      decoration:
                          isCurrentMove ? null : TextDecoration.underline,
                      decorationColor:
                          AppColors.onSurfaceDim.withValues(alpha: 0.45),
                      decorationStyle: TextDecorationStyle.dotted,
                    ),
                  ),
                  if (nagSuffix.isNotEmpty)
                    TextSpan(
                      text: nagSuffix,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: nagMoveColor ?? AppColors.pgnMove,
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
      );

      spans.add(const TextSpan(text: ' '));

      // Annotation toolbar (edit mode only)
      if (isSelected && editingCommentIndex != i) {
        flushSpans();
        children.add(_AnnotationToolbar(
          moveIndex: i,
          currentNags: moveData.nags ?? [],
          onToggleNag: (nagId) => onToggleNag(i, nagId),
          onComment: () => onStartEditingComment(i),
          onDismiss: onDismissAnnotation,
        ));
      }

      // Inline comment editor
      if (editingCommentIndex == i) {
        flushSpans();
        children.add(_CommentEditor(
          initialText: _rawComment(moveData),
          onSave: (text) => onSaveComment(i, text),
          onCancel: onCancelEditingComment,
        ));
      } else if (moveData.comments != null && moveData.comments!.isNotEmpty) {
        final raw = moveData.comments!.first;
        final comment = _filterComment(raw);
        if (comment.isNotEmpty) {
          final paragraphs = formatProseComment(raw);
          if (paragraphs.length > 1 || comment.length > 200) {
            flushSpans();
            children.add(_buildProseBlock(paragraphs));
          } else {
            spans.add(_buildCommentSpan(comment));
          }
        }
      }

      // Render variations at this ply (ply = i+1 because variations branch
      // *after* the move at index i has been played)
      final ply = i + 1;
      final varsHere = variationsByPly[ply];
      if (varsHere != null && varsHere.isNotEmpty) {
        spans.addAll(_buildVariationSpansAtPly(ply));
      }

      if (!isWhiteTurn) moveNumber++;
      isWhiteTurn = !isWhiteTurn;
    }

    // Variations after last move
    final endPly = moveHistory.length;
    final varsAtEnd = variationsByPly[endPly];
    if (varsAtEnd != null && varsAtEnd.isNotEmpty) {
      spans.addAll(_buildVariationSpansAtPly(endPly));
    }

    flushSpans();

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  /// Build an inline comment WidgetSpan (short comments alongside moves).
  WidgetSpan _buildCommentSpan(String comment) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: Text(
        '$comment ',
        style: const TextStyle(
          fontSize: 14,
          height: 1.35,
          color: AppColors.pgnComment,
        ),
      ),
    );
  }

  /// Build a prose block widget for long/multi-paragraph comments (book-style).
  Widget _buildProseBlock(List<String> paragraphs) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.pgnComment.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(
            color: AppColors.pgnComment.withValues(alpha: 0.3),
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < paragraphs.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            Text(
              paragraphs[i],
              style: const TextStyle(
                fontSize: 13.5,
                height: 1.5,
                color: AppColors.pgnComment,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Build variation spans for all roots at a given ply.
  List<InlineSpan> _buildVariationSpansAtPly(int ply) {
    final roots = variationsByPly[ply];
    if (roots == null || roots.isEmpty) return const [];

    final spans = <InlineSpan>[];
    final moveNum = (ply ~/ 2) + 1;
    final isWhiteTurn = ply % 2 == 0;

    for (final root in roots) {
      final bracketColor = root.isEphemeral
          ? AppColors.pgnEphemeralMove
          : AppColors.pgnVariation;

      spans.add(TextSpan(
        text: '( ',
        style: TextStyle(
          color: bracketColor,
          fontFamily: 'monospace',
        ),
      ));

      spans.addAll(_buildNodeSpans(root, moveNum, isWhiteTurn, true, ply));

      spans.add(TextSpan(
        text: ') ',
        style: TextStyle(
          color: bracketColor,
          fontFamily: 'monospace',
        ),
      ));
    }

    return spans;
  }

  /// Recursively build spans for a node and its children.
  List<InlineSpan> _buildNodeSpans(MoveNode node, int moveNumber,
      bool isWhiteTurn, bool isFirst, int branchPly) {
    final spans = <InlineSpan>[];
    final moveColor =
        node.isEphemeral ? AppColors.pgnEphemeralMove : AppColors.pgnVariation;
    const numColor = AppColors.pgnMoveNumber;

    // For null-move variation nodes, skip the move display entirely and just
    // show the comment inline.
    if (node.san == '--') {
      if (node.comment != null && node.comment!.isNotEmpty) {
        final filtered = _filterComment(node.comment!);
        if (filtered.isNotEmpty) {
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Text(
              '$filtered ',
              style: const TextStyle(
                fontSize: 13.5,
                height: 1.4,
                color: AppColors.pgnComment,
              ),
            ),
          ));
        }
      }
      return spans;
    }

    if (isWhiteTurn) {
      spans.add(TextSpan(
        text: '$moveNumber. ',
        style: const TextStyle(
          color: numColor,
          fontFamily: 'monospace',
        ),
      ));
    } else if (isFirst) {
      spans.add(TextSpan(
        text: '$moveNumber... ',
        style: const TextStyle(
          color: numColor,
          fontFamily: 'monospace',
        ),
      ));
    }

    final isCurrentNode =
        analysisPath.isNotEmpty && analysisPath.last.id == node.id;

    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onGoToAnalysisNode(node, branchPly),
          onSecondaryTapDown: onAnalysisNodeAction != null && node.isEphemeral
              ? (details) =>
                  onAnalysisNodeAction!(node.id, details.globalPosition)
              : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: isCurrentNode
                ? BoxDecoration(
                    color: node.isEphemeral
                        ? AppColors.pgnEphemeralBg
                        : AppColors.pgnMoveCurrentBg,
                    borderRadius: BorderRadius.circular(3),
                  )
                : null,
            child: Text(
              node.san,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                color: isCurrentNode
                    ? (node.isEphemeral
                        ? AppColors.pgnMoveCurrent
                        : AppColors.pgnMainLine)
                    : moveColor,
                fontWeight: isCurrentNode ? FontWeight.w500 : FontWeight.normal,
                decoration: isCurrentNode ? null : TextDecoration.underline,
                decorationColor: AppColors.onSurfaceDim.withValues(alpha: 0.45),
                decorationStyle: TextDecorationStyle.dotted,
              ),
            ),
          ),
        ),
      ),
    );

    spans.add(const TextSpan(text: ' '));

    // Show comment after the move (for non-null-move variation nodes)
    if (node.comment != null && node.comment!.isNotEmpty) {
      final filtered = _filterComment(node.comment!);
      if (filtered.isNotEmpty) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Text(
            '$filtered ',
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.4,
              color: AppColors.pgnComment,
            ),
          ),
        ));
      }
    }

    final nextMoveNumber = isWhiteTurn ? moveNumber : moveNumber + 1;
    final nextIsWhite = !isWhiteTurn;

    if (node.children.isNotEmpty) {
      spans.addAll(_buildNodeSpans(
          node.children.first, nextMoveNumber, nextIsWhite, false, branchPly));

      for (int i = 1; i < node.children.length; i++) {
        final variation = node.children[i];
        final subColor = variation.isEphemeral
            ? AppColors.pgnEphemeralMove
            : AppColors.pgnVariation;

        spans.add(TextSpan(
          text: '( ',
          style: TextStyle(
            color: subColor,
            fontFamily: 'monospace',
          ),
        ));
        spans.addAll(_buildNodeSpans(
            variation, nextMoveNumber, nextIsWhite, true, branchPly));
        spans.add(TextSpan(
          text: ') ',
          style: TextStyle(
            color: subColor,
            fontFamily: 'monospace',
          ),
        ));
      }
    }

    return spans;
  }
}

// ---------------------------------------------------------------------------
// Annotation toolbar widget (edit mode)
// ---------------------------------------------------------------------------
class _AnnotationToolbar extends StatelessWidget {
  final int moveIndex;
  final List<int> currentNags;
  final ValueChanged<int> onToggleNag;
  final VoidCallback onComment;
  final VoidCallback onDismiss;

  const _AnnotationToolbar({
    required this.moveIndex,
    required this.currentNags,
    required this.onToggleNag,
    required this.onComment,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.grey.withValues(alpha: 0.25),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final nag in kMoveNags)
            _NagButton(
              nag: nag,
              isActive: currentNags.contains(nag.id),
              onTap: () => onToggleNag(nag.id),
            ),
          const SizedBox(width: 4),
          Container(
            width: 1,
            height: 22,
            color: Colors.grey.withValues(alpha: 0.3),
          ),
          const SizedBox(width: 4),
          _ToolbarIconButton(
            icon: Icons.comment_outlined,
            tooltip: 'Comment',
            onTap: onComment,
          ),
          const SizedBox(width: 2),
          _ToolbarIconButton(
            icon: Icons.close,
            tooltip: 'Dismiss',
            onTap: onDismiss,
            color: Colors.grey[600],
          ),
        ],
      ),
    );
  }
}

class _NagButton extends StatelessWidget {
  final NagInfo nag;
  final bool isActive;
  final VoidCallback onTap;

  const _NagButton({
    required this.nag,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: nag.name,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: isActive ? nag.color.withValues(alpha: 0.2) : null,
            borderRadius: BorderRadius.circular(4),
            border: isActive
                ? Border.all(color: nag.color.withValues(alpha: 0.6), width: 1)
                : null,
          ),
          child: Text(
            nag.symbol,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              color: isActive ? nag.color : Colors.grey[400],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  const _ToolbarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 18, color: color ?? Colors.grey[400]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Inline comment editor widget
// ---------------------------------------------------------------------------
class _CommentEditor extends StatefulWidget {
  final String initialText;
  final ValueChanged<String> onSave;
  final VoidCallback onCancel;

  const _CommentEditor({
    required this.initialText,
    required this.onSave,
    required this.onCancel,
  });

  @override
  State<_CommentEditor> createState() => _CommentEditorState();
}

class _CommentEditorState extends State<_CommentEditor> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              maxLines: null,
              style: TextStyle(fontSize: 13, color: Colors.grey[200]),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                border: InputBorder.none,
                hintText: 'Comment',
                hintStyle: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
              onSubmitted: (v) => widget.onSave(v),
            ),
          ),
          IconButton(
            onPressed: () => widget.onSave(_controller.text),
            icon: Icon(Icons.check, size: 18, color: Colors.grey[400]),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          IconButton(
            onPressed: widget.onCancel,
            icon: Icon(Icons.close, size: 18, color: Colors.grey[500]),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }
}
