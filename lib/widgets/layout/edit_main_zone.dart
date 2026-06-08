/// PGN editor column in Edit mode (B4 Phase 1 extraction).
///
/// Wraps [InteractivePgnEditor] — the main editable content below the
/// analysis dock in [PgnWithAnalysisPane].
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import '../interactive_pgn_editor.dart';

class EditMainZone extends StatelessWidget {
  const EditMainZone({
    super.key,
    required this.tree,
    required this.currentPath,
    this.onJump,
    this.onCommentChanged,
    this.onDelete,
    this.onPromote,
    this.repertoireName,
    required this.repertoireColor,
    required this.isEditingExistingLine,
    this.onLineEdited,
    this.onLineSaved,
    this.trapIndex,
    this.boardPreview,
  });

  final MoveTree tree;
  final TreePath currentPath;
  final ValueChanged<TreePath>? onJump;
  final void Function(TreePath path, String? comment)? onCommentChanged;
  final void Function(TreePath path)? onDelete;
  final void Function(TreePath path)? onPromote;
  final String? repertoireName;
  final String repertoireColor;
  final bool isEditingExistingLine;
  final void Function(String updatedPgn)? onLineEdited;
  final void Function(List<String> moves, String title, String pgn)? onLineSaved;
  final TrapIndexService? trapIndex;
  final BoardPreviewController? boardPreview;

  @override
  Widget build(BuildContext context) {
    return InteractivePgnEditor(
      tree: tree,
      currentPath: currentPath,
      onJump: onJump,
      onCommentChanged: onCommentChanged,
      onDelete: onDelete,
      onPromote: onPromote,
      currentRepertoireName: repertoireName,
      repertoireColor: repertoireColor,
      isEditingExistingLine: isEditingExistingLine,
      onLineEdited: onLineEdited,
      onLineSaved: onLineSaved,
      trapIndex: trapIndex,
      boardPreview: boardPreview,
    );
  }
}
