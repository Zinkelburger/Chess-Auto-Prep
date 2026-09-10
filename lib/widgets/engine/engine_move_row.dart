import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../models/engine_settings.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/chess_utils.dart';
import '../../utils/fen_utils.dart';
import 'engine_pv_row.dart';
import '../../models/merged_move.dart';

/// One row of the unified engine table: eval + move SAN + PV continuation
/// (+ Maia%). Extracted from `unified_engine_pane.dart`. Hover/preview and
/// tap callbacks are driven through the injected [boardPreview] and callbacks;
/// [previewStackKey] is the parent's preview stack anchor.
class EngineMoveRow extends StatelessWidget {
  final MergedMove move;
  final EngineSettings settings;
  final String fen;
  final BoardPreviewController? boardPreview;
  final void Function(String uci)? onMoveSelected;
  final void Function(List<String> sanMoves, int clickedIndex)?
  onLineMoveTapped;
  final GlobalKey previewStackKey;

  const EngineMoveRow({
    super.key,
    required this.move,
    required this.settings,
    required this.fen,
    required this.boardPreview,
    required this.onMoveSelected,
    required this.onLineMoveTapped,
    required this.previewStackKey,
  });

  @override
  Widget build(BuildContext context) {
    final pv = move.fullPv.isEmpty ? [move.uci] : move.fullPv;
    final sanMoves = uciPvToSanCached(fen, pv);
    return LayoutBuilder(
      builder: (context, constraints) => EnginePvRow(
        key: ValueKey('$fen:${move.uci}'),
        evaluation: move.evalString,
        sanMoves: sanMoves,
        startPly: plyFromFen(fen),
        rows: settings.pvRows,
        evalColor:
            !move.hasStockfish ||
                settings.isAnalysisColumnMuted(EngineSettings.colEval)
            ? AppColors.onSurfaceMuted
            : AppColors.ink,
        moveColor: settings.isAnalysisColumnMuted(EngineSettings.colLine)
            ? AppColors.onSurfaceMuted
            : AppColors.ink,
        trailing:
            constraints.maxWidth >= 200 &&
                settings.showMaia &&
                settings.fetchMaiaForOpponent
            ? SizedBox(
                width: 46,
                child: Text(
                  move.maiaProb != null
                      ? '${(move.maiaProb! * 100).toStringAsFixed(0)}%'
                      : '--',
                  textAlign: TextAlign.right,
                  style: AppTextStyles.mono.copyWith(
                    color: AppColors.maiaColor(
                      muted: settings.isAnalysisColumnMuted(
                        EngineSettings.colMaia,
                      ),
                    ),
                  ),
                ),
              )
            : null,
        onMoveTapped: onLineMoveTapped != null || onMoveSelected != null
            ? (idx) {
                if (onLineMoveTapped != null) {
                  onLineMoveTapped!(sanMoves, idx);
                } else {
                  onMoveSelected?.call(move.uci);
                }
                boardPreview?.clearPreview();
              }
            : null,
        onMoveHovered: boardPreview == null
            ? null
            : (idx, anchor) {
                boardPreview!.setPreview(
                  fenAfterMoves(fen, sanMoves, idx),
                  moves: sanMoves.sublist(0, idx + 1),
                  target: BoardPreviewTarget.floating,
                  lastMoveUci: idx < pv.length ? pv[idx] : null,
                  anchorGlobal: anchor,
                  ownerTag: previewStackKey,
                );
              },
        onHoverExit: boardPreview?.clearPreview,
      ),
    );
  }
}
