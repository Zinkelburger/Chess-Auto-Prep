/// PGN editor column in Edit mode (B4 Phase 1 extraction).
///
/// Wraps [InteractivePgnEditor] — the main editable content below the
/// analysis dock in [PgnWithAnalysisPane].
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/utils/app_messages.dart';
import '../interactive_pgn_editor.dart';

Future<void> _persistNewLineToRepertoire(String repertoireName, String pgn) async {
  final filename = 'repertoires/$repertoireName.pgn';
  final currentContent =
      await StorageFactory.instance.readRepertoirePgn(filename) ?? '';

  final separator = currentContent.trimRight().isEmpty ? '' : '\n\n';
  final entry = '$separator$pgn\n';

  await StorageFactory.instance
      .saveRepertoirePgn(filename, currentContent + entry);
}

void _copyToClipboard(BuildContext context, String text, String message) {
  Clipboard.setData(ClipboardData(text: text));
  showAppSnackBar(context, message);
}

class EditMainZone extends StatelessWidget {
  const EditMainZone({
    super.key,
    required this.tree,
    required this.currentPath,
    this.onJump,
    this.onCommentChanged,
    this.onDelete,
    this.onPromote,
    this.onMakeMainLine,
    this.repertoireName,
    required this.repertoireColor,
    required this.isEditingExistingLine,
    this.onLineEdited,
    this.onAutoSave,
    this.onDirty,
    this.onLineSaved,
    this.onPersistNewLine,
    this.onCopyToClipboard,
    this.trapIndex,
    this.boardPreview,
  });

  final MoveTree tree;
  final TreePath currentPath;
  final ValueChanged<TreePath>? onJump;
  final void Function(TreePath path, String? comment)? onCommentChanged;
  final void Function(TreePath path)? onDelete;
  final void Function(TreePath path)? onPromote;
  final void Function(TreePath path)? onMakeMainLine;
  final String? repertoireName;
  final String repertoireColor;
  final bool isEditingExistingLine;
  final void Function(String updatedPgn)? onLineEdited;
  final ValueChanged<String>? onAutoSave;
  final VoidCallback? onDirty;
  final void Function(List<String> moves, String title, String pgn)? onLineSaved;
  final Future<void> Function(String repertoireName, String pgn)?
      onPersistNewLine;
  final void Function(String text, String successMessage)? onCopyToClipboard;
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
      onMakeMainLine: onMakeMainLine,
      currentRepertoireName: repertoireName,
      repertoireColor: repertoireColor,
      isEditingExistingLine: isEditingExistingLine,
      onLineEdited: onLineEdited,
      onAutoSave: onAutoSave,
      onDirty: onDirty,
      onLineSaved: onLineSaved,
      onPersistNewLine: onPersistNewLine ?? _persistNewLineToRepertoire,
      onCopyToClipboard: onCopyToClipboard ??
          (text, message) => _copyToClipboard(context, text, message),
      trapIndex: trapIndex,
      boardPreview: boardPreview,
    );
  }
}
