/// Board column in the repertoire layout (B4 Phase 1 extraction).
///
/// Wraps [RepertoireBoardPane]. [BoardZoneControls] groups trap navigation
/// on the app bar.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../chess_board_widget.dart' show BoardAnnotation, CompletedMove;
import '../repertoire/repertoire_board_pane.dart';

/// Chess board with preview overlay. Generation locking is handled by the
/// screen-level [GenerationLockOverlay], not here.
class BoardZone extends StatelessWidget {
  const BoardZone({
    super.key,
    required this.boardPreview,
    required this.fen,
    required this.positionFromFen,
    required this.boardFlipped,
    required this.onMove,
    this.annotations = const [],
  });

  final BoardPreviewController boardPreview;
  final String fen;
  final Position Function(String fen) positionFromFen;
  final bool boardFlipped;
  final void Function(CompletedMove move) onMove;
  final List<BoardAnnotation> annotations;

  @override
  Widget build(BuildContext context) {
    return RepertoireBoardPane(
      boardPreview: boardPreview,
      fen: fen,
      positionFromFen: positionFromFen,
      boardFlipped: boardFlipped,
      onMove: onMove,
      annotations: annotations,
    );
  }
}

/// Trap navigation on the app bar. Engine on/off lives in Settings.
class BoardZoneControls extends StatelessWidget {
  const BoardZoneControls({super.key, this.trapNavigation});

  final Widget? trapNavigation;

  @override
  Widget build(BuildContext context) {
    if (trapNavigation == null) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: [trapNavigation!]);
  }
}
