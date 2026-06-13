/// Orange dot marker for trap positions in move lists and PGN panes.
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../models/trap_line_info.dart';
import '../../../theme/app_colors.dart';

/// Small orange dot shown beside a move when the position is a trap.
class TrapMoveIndicator extends StatelessWidget {
  const TrapMoveIndicator({
    super.key,
    required this.trap,
    this.boardPreview,
    this.previewFen,
    this.previewMoves,
    this.ownerTag,
    this.size = 6,
  });

  final TrapLineInfo trap;
  final BoardPreviewController? boardPreview;
  final String? previewFen;
  final List<String>? previewMoves;
  final Object? ownerTag;
  final double size;

  String get _tooltip {
    final parts = <String>[
      'Trap: ${trap.mistakeDescription} (+${trap.evalDiffCp}cp)',
      '${(trap.popularProb * 100).toStringAsFixed(0)}% play ${trap.popularMove}',
      'Reach: ${(trap.cumulativeProb * 100).toStringAsFixed(1)}%',
    ];
    if (trap.trapScore > 0) {
      parts.add(
          'Score: ${(trap.trapScore * 100).toStringAsFixed(0)}%');
    }
    return parts.join('\n');
  }

  void _onEnter(PointerEvent event) {
    final preview = boardPreview;
    if (preview == null) return;
    final fen = previewFen ?? trap.fen;
    if (fen == null) return;
    preview.setPreview(
      fen,
      moves: previewMoves ?? trap.movesSan,
      ownerTag: ownerTag,
    );
  }

  void _onExit(PointerEvent event) {
    boardPreview?.clearPreview();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: size,
      height: size,
      margin: const EdgeInsets.only(left: 3),
      decoration: const BoxDecoration(
        color: AppColors.warning,
        shape: BoxShape.circle,
      ),
    );

    Widget child = Tooltip(message: _tooltip, child: dot);

    if (boardPreview != null && (previewFen ?? trap.fen) != null) {
      child = MouseRegion(
        onEnter: _onEnter,
        onExit: _onExit,
        child: child,
      );
    }

    return child;
  }
}
