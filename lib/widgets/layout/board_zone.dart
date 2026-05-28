/// Board column in the repertoire layout (B4 Phase 1 extraction).
///
/// Wraps [RepertoireBoardPane]. [BoardZoneControls] groups trap navigation
/// and the engine toggle; they stay on [RepertoireToolbar] until B4 Phase 2.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../chess_board_widget.dart' show CompletedMove;
import '../engine/engine_toggle_button.dart';
import '../repertoire/repertoire_board_pane.dart';

/// Chess board with preview overlay and generation lock UI.
class BoardZone extends StatelessWidget {
  const BoardZone({
    super.key,
    required this.boardPreview,
    required this.fen,
    required this.positionFromFen,
    required this.boardFlipped,
    required this.isGenerating,
    required this.isGenerationPaused,
    required this.onMove,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
  });

  final BoardPreviewController boardPreview;
  final String fen;
  final Position Function(String fen) positionFromFen;
  final bool boardFlipped;
  final bool isGenerating;
  final bool isGenerationPaused;
  final void Function(CompletedMove move) onMove;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return RepertoireBoardPane(
      boardPreview: boardPreview,
      fen: fen,
      positionFromFen: positionFromFen,
      boardFlipped: boardFlipped,
      isGenerating: isGenerating,
      isGenerationPaused: isGenerationPaused,
      onMove: onMove,
      onPause: onPause,
      onResume: onResume,
      onCancel: onCancel,
    );
  }
}

/// Trap navigation + engine toggle. Mounted on the app bar for now;
/// moves below the board in B4 Phase 2.
class BoardZoneControls extends StatelessWidget {
  const BoardZoneControls({
    super.key,
    this.trapNavigation,
  });

  final Widget? trapNavigation;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (trapNavigation != null) ...[
          trapNavigation!,
          const SizedBox(width: 4),
        ],
        const EngineToggleButton(),
      ],
    );
  }
}
