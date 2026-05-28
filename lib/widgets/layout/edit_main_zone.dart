/// PGN editor column in Edit mode (B4 Phase 1 extraction).
///
/// Wraps [InteractivePgnEditor] — the main editable content below the
/// analysis dock in [PgnWithAnalysisPane].
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import '../interactive_pgn_editor.dart';

class EditMainZone extends StatelessWidget {
  const EditMainZone({
    super.key,
    required this.pgnEditorController,
    required this.editorKeySuffix,
    required this.initialPgn,
    this.repertoireName,
    required this.repertoireColor,
    required this.moveHistory,
    required this.currentMoveIndex,
    this.startingFen,
    required this.onMoveStateChanged,
    required this.onPositionChanged,
    required this.onPgnChanged,
    required this.isEditingExistingLine,
    this.onLineEdited,
    this.onLineSaved,
    this.trapIndex,
    this.boardPreview,
  });

  final PgnEditorController pgnEditorController;
  final String editorKeySuffix;
  final String initialPgn;
  final String? repertoireName;
  final String repertoireColor;
  final List<String> moveHistory;
  final int currentMoveIndex;
  final String? startingFen;
  final void Function(int moveIndex, List<String> moves) onMoveStateChanged;
  final void Function(dynamic position) onPositionChanged;
  final void Function(String pgn) onPgnChanged;
  final bool isEditingExistingLine;
  final void Function(String updatedPgn)? onLineEdited;
  final void Function(List<String> moves, String title, String pgn)? onLineSaved;
  final TrapIndexService? trapIndex;
  final BoardPreviewController? boardPreview;

  @override
  Widget build(BuildContext context) {
    return InteractivePgnEditor(
      key: ValueKey('${editorKeySuffix}_${startingFen ?? 'standard'}'),
      controller: pgnEditorController,
      initialPgn: initialPgn,
      currentRepertoireName: repertoireName,
      repertoireColor: repertoireColor,
      moveHistory: moveHistory,
      currentMoveIndex: currentMoveIndex,
      startingFen: startingFen,
      onMoveStateChanged: onMoveStateChanged,
      onPositionChanged: onPositionChanged,
      onPgnChanged: onPgnChanged,
      isEditingExistingLine: isEditingExistingLine,
      onLineEdited: onLineEdited,
      onLineSaved: onLineSaved,
      trapIndex: trapIndex,
      boardPreview: boardPreview,
    );
  }
}
