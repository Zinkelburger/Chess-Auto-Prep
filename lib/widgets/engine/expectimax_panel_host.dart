/// The expectimax pane wired to a [RepertoireController]: follows the cursor
/// (or a caller-supplied FEN) and plays moves back into the controller.
///
/// Shared by [RepertoireAnalysisDock], [InlineExpectimaxBar] and
/// [EditContextZone] so all three show the same thing for a position.
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';

import '../../core/repertoire_controller.dart';
import '../../models/build_tree_node.dart';
import '../../services/coherence_service.dart';
import '../../services/generation/fen_map.dart';
import '../../services/generation/generation_config.dart';
import 'expectimax_lines_pane.dart';

class ExpectimaxPanelHost extends StatelessWidget {
  final RepertoireController controller;
  final BuildTree? tree;
  final TreeBuildConfig? treeConfig;
  final FenMap? fenMap;
  final BoardPreviewController boardPreview;
  final CoherenceResult? coherenceResult;
  final bool compact;
  final void Function(String san)? onMoveSelected;
  final void Function(List<String> sanMoves, int index)? onLineMoveClicked;

  /// Show this FEN instead of the controller cursor (e.g. the
  /// build-by-playing scratchpad position).
  final String? fenOverride;

  const ExpectimaxPanelHost({
    super.key,
    required this.controller,
    this.tree,
    this.treeConfig,
    this.fenMap,
    required this.boardPreview,
    this.coherenceResult,
    this.compact = false,
    this.onMoveSelected,
    this.onLineMoveClicked,
    this.fenOverride,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ExpectimaxLinesPane(
        fen: fenOverride ?? controller.fen,
        tree: tree,
        config: treeConfig,
        fenMap: fenMap,
        isWhiteRepertoire: controller.isRepertoireWhite,
        boardPreview: boardPreview,
        coherenceResult: coherenceResult,
        compact: compact,
        onMoveSelected: onMoveSelected ?? controller.playMove,
        onLineMoveClicked:
            onLineMoveClicked ??
            (sanMoves, index) {
              controller.applyLineFromCurrent(sanMoves, index);
              boardPreview.clearPreview();
            },
      ),
    );
  }
}
