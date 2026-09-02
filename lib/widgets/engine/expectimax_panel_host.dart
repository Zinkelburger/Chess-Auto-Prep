/// The expectimax pane wired to a [RepertoireController]: follows the cursor
/// (or a caller-supplied FEN) and plays moves back into the controller.
///
/// Shared by [RepertoireAnalysisDock], [InlineExpectimaxBar] and
/// [EditContextZone] so all three show the same thing for a position.
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';

import '../../constants/chess_constants.dart';
import '../../core/generation_session_controller.dart';
import '../../core/repertoire_controller.dart';
import '../../models/build_tree_node.dart';
import '../../services/coherence_service.dart';
import '../../services/generation/fen_map.dart';
import '../../services/generation/generation_config.dart';
import 'expectimax_lines_pane.dart';
import 'expectimax_probe_hooks.dart';

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

  /// Lets the pane start on-demand probes. Null (or a [fenOverride], whose
  /// move sequence the controller does not know) leaves the pane read-only.
  final GenerationSessionController? generation;

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
    this.generation,
  });

  ExpectimaxProbeHooks? _hooks() {
    final gen = generation;
    if (gen == null || fenOverride != null) return null;
    final repertoire = controller.currentRepertoire;
    if (repertoire == null) return null;
    return ExpectimaxProbeHooks(
      generation: gen,
      compute: ({String? moveSan, required int plies}) => gen.computeExpectimax(
        ExpectimaxProbeTarget(
          repertoireFilePath: repertoire.filePath,
          repertoireStartFen: controller.startingFen ?? kStandardStartFen,
          movesFromStart: List.of(controller.currentMoveSequence),
          moveSan: moveSan,
          plies: plies,
          playAsWhite: controller.isRepertoireWhite,
        ),
      ),
    );
  }

  Widget _pane(ExpectimaxProbeHooks? hooks) => ExpectimaxLinesPane(
    fen: fenOverride ?? controller.fen,
    tree: tree,
    config: treeConfig,
    fenMap: fenMap,
    isWhiteRepertoire: controller.isRepertoireWhite,
    boardPreview: boardPreview,
    coherenceResult: coherenceResult,
    compact: compact,
    hooks: hooks,
    onMoveSelected: onMoveSelected ?? controller.playMove,
    onLineMoveClicked:
        onLineMoveClicked ??
        (sanMoves, index) {
          controller.applyLineFromCurrent(sanMoves, index);
          boardPreview.clearPreview();
        },
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final hooks = _hooks();
        if (hooks == null) return _pane(null);
        // Progress ticks while a probe runs; the pane shows them inline.
        return ListenableBuilder(
          listenable: hooks.generation,
          builder: (_, _) => _pane(hooks),
        );
      },
    );
  }
}
