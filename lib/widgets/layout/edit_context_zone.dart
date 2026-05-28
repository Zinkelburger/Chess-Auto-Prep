/// Context panel in Edit mode.
///
/// Shows engine output, expectimax lines, or opening tree,
/// switchable via chips. All sub-views support hover preview.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../core/repertoire_controller.dart';
import '../../models/build_tree_node.dart';
import '../../services/board_preview_controller.dart';
import '../../services/generation/fen_map.dart';
import '../../services/generation/generation_config.dart';
import '../../utils/chess_utils.dart' show uciToSan;
import '../engine/expectimax_lines_pane.dart';
import '../opening_tree_widget.dart';
import '../unified_engine_pane.dart';
import 'repertoire_mode.dart';

class EditContextZone extends StatefulWidget {
  final RepertoireController controller;
  final BuildTree? tree;
  final TreeBuildConfig? treeConfig;
  final FenMap? fenMap;
  final BoardPreviewController boardPreview;
  final bool isGenerating;
  final bool isGenerationPaused;

  const EditContextZone({
    super.key,
    required this.controller,
    this.tree,
    this.treeConfig,
    this.fenMap,
    required this.boardPreview,
    this.isGenerating = false,
    this.isGenerationPaused = false,
  });

  @override
  State<EditContextZone> createState() => _EditContextZoneState();
}

class _EditContextZoneState extends State<EditContextZone> {
  EditContextView _view = EditContextView.engine;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildChipBar(),
        const Divider(height: 1),
        Expanded(child: _buildContent()),
      ],
    );
  }

  Widget _buildChipBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          _chip('Engine', EditContextView.engine, Icons.bolt),
          const SizedBox(width: 6),
          _chip('Expectimax', EditContextView.expectimax, Icons.analytics),
          const SizedBox(width: 6),
          _chip('Tree', EditContextView.tree, Icons.account_tree),
        ],
      ),
    );
  }

  Widget _chip(String label, EditContextView view, IconData icon) {
    final isSelected = _view == view;
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: 14,
              color: isSelected
                  ? Colors.teal
                  : Colors.grey[500]),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11)),
        ],
      ),
      selected: isSelected,
      onSelected: (_) => setState(() => _view = view),
      visualDensity: VisualDensity.compact,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _buildContent() {
    return switch (_view) {
      EditContextView.engine => _buildEngine(),
      EditContextView.expectimax => _buildExpectimax(),
      EditContextView.tree => _buildTree(),
    };
  }

  Widget _buildEngine() {
    return UnifiedEnginePane(
      fen: widget.controller.fen,
      isActive: !widget.isGenerating || widget.isGenerationPaused,
      isUserTurn: widget.controller.position.turn ==
          (widget.controller.isRepertoireWhite ? Side.white : Side.black),
      currentMoveSequence: widget.controller.currentMoveSequence,
      isWhiteRepertoire: widget.controller.isRepertoireWhite,
      boardPreview: widget.boardPreview,
      onMoveSelected: (uciMove) {
        final san = uciToSan(widget.controller.fen, uciMove);
        if (san != uciMove) {
          widget.controller.userPlayedMove(san);
        }
      },
      onLineMoveTapped: (sanMoves, index) {
        widget.controller.applyLineFromCurrent(sanMoves, index);
        widget.boardPreview.clearPreview();
      },
    );
  }

  Widget _buildExpectimax() {
    if (widget.tree == null || widget.treeConfig == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.analytics_outlined, size: 36, color: Colors.grey),
            SizedBox(height: 12),
            Text(
              'No tree loaded',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            SizedBox(height: 4),
            Text(
              'Generate a tree to see expectimax lines',
              style: TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ],
        ),
      );
    }

    return ExpectimaxLinesPane(
      fen: widget.controller.fen,
      tree: widget.tree,
      config: widget.treeConfig,
      fenMap: widget.fenMap,
      isWhiteRepertoire: widget.controller.isRepertoireWhite,
      boardPreview: widget.boardPreview,
      onMoveSelected: (san) {
        widget.controller.userPlayedMove(san);
      },
      onLineMoveClicked: (sanMoves, index) {
        widget.controller.applyLineFromCurrent(sanMoves, index);
        widget.boardPreview.clearPreview();
      },
    );
  }

  Widget _buildTree() {
    if (widget.controller.openingTree == null) {
      return const Center(
        child: Text('No opening tree available',
            style: TextStyle(color: Colors.grey)),
      );
    }
    return OpeningTreeWidget(
      tree: widget.controller.openingTree!,
      repertoireLines: widget.controller.repertoireLines,
      currentMoveSequence: widget.controller.currentMoveSequence,
      onMoveSelected: (move) {
        widget.controller.userPlayedMove(move);
      },
    );
  }
}
