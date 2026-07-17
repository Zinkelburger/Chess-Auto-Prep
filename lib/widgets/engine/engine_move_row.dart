import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../models/engine_settings.dart';
import '../../theme/app_colors.dart';
import '../../utils/chess_utils.dart';
import '../../utils/fen_utils.dart';
import '../clickable_move_line.dart';
import '../../models/merged_move.dart';

/// One row of the unified engine table: move SAN + eval chip + PV continuation
/// (+ Maia%). Extracted from `unified_engine_pane.dart`. Hover/preview and
/// tap callbacks are driven through the injected [boardPreview] and callbacks;
/// [previewStackKey] is the parent's preview stack anchor.
class EngineMoveRow extends StatelessWidget {
  static const double _narrowTableWidth = 200;

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
    final evalMuted = settings.isAnalysisColumnMuted(EngineSettings.colEval);
    final lineMuted = settings.isAnalysisColumnMuted(EngineSettings.colLine);
    final maiaMuted = settings.isAnalysisColumnMuted(EngineSettings.colMaia);

    final evalColor = move.hasStockfish
        ? AppColors.cpEval(move.effectiveCp, muted: evalMuted)
        : AppColors.onSurfaceDim;

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < _narrowTableWidth;
        final showMaia =
            !narrow && settings.showMaia && settings.fetchMaiaForOpponent;
        final moveWidth = narrow ? 36.0 : 52.0;
        final evalWidth = narrow ? 44.0 : 58.0;
        final hPad = narrow ? 4.0 : 12.0;

        return InkWell(
          onTap: () => onMoveSelected?.call(move.uci),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 6),
            child: Row(
              children: [
                Builder(
                  builder: (anchorContext) {
                    return MouseRegion(
                      onEnter: boardPreview != null
                          ? (_) {
                              final box =
                                  anchorContext.findRenderObject()
                                      as RenderBox?;
                              if (box == null) return;
                              final anchor = box.localToGlobal(
                                Offset(box.size.width / 2, box.size.height),
                              );
                              _previewEngineMove(move, anchor);
                            }
                          : null,
                      onExit: boardPreview != null
                          ? (_) => boardPreview!.clearPreview()
                          : null,
                      child: SizedBox(
                        width: moveWidth,
                        child: Text(
                          move.san,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                            fontSize: 15,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    );
                  },
                ),
                Container(
                  width: evalWidth,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: move.hasStockfish
                        ? AppColors.cpEvalBg(
                            move.effectiveCp,
                            muted: evalMuted,
                          ).withValues(alpha: evalMuted ? 0.5 : 0.85)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    move.evalString,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: evalColor,
                      fontFamily: 'monospace',
                    ),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!narrow) const SizedBox(width: 8),
                Expanded(child: _buildContinuation(move, muted: lineMuted)),
                if (showMaia)
                  SizedBox(
                    width: narrow ? 40 : 46,
                    child: Text(
                      move.maiaProb != null
                          ? '${(move.maiaProb! * 100).toStringAsFixed(0)}%'
                          : '--',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 14,
                        color: move.maiaProb != null
                            ? AppColors.maiaColor(muted: maiaMuted)
                            : AppColors.onSurfaceDim,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildContinuation(MergedMove move, {bool muted = false}) {
    final lineColor = muted ? AppColors.onSurfaceDim : AppColors.onSurfaceMuted;
    if (move.fullPv.length <= 1 || boardPreview == null) {
      final continuation = formatContinuation(fen, move.fullPv);
      return Text(
        continuation,
        style: TextStyle(
          fontSize: 13,
          color: lineColor,
          fontFamily: 'monospace',
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final afterFirstMove = playUciMove(fen, move.uci);
    if (afterFirstMove == null) return const SizedBox.shrink();

    final continuationUci = move.fullPv.sublist(1);
    // Cached: MultiPV rows re-render on every info line during a live search;
    // re-parsing the FEN + replaying the PV each frame is what drops frames.
    final sanMoves = uciPvToSanCached(afterFirstMove, continuationUci);
    if (sanMoves.isEmpty) return const SizedBox.shrink();

    final fenParts = afterFirstMove.split(' ');
    final fullMoveNumber =
        int.tryParse(fenParts.length >= 6 ? fenParts[5] : '1') ?? 1;
    final isBlack = !isWhiteToMove(afterFirstMove);
    final startPly = (fullMoveNumber - 1) * 2 + (isBlack ? 1 : 0);

    return ClickableMoveLineWidget(
      sanMoves: sanMoves,
      startPly: startPly,
      maxMoves: 8,
      fontSize: 13,
      onMoveTapped: (idx) {
        if (onLineMoveTapped != null) {
          final fullLine = [move.san, ...sanMoves];
          onLineMoveTapped!(fullLine, idx + 1);
          boardPreview?.clearPreview();
        } else if (idx < continuationUci.length) {
          onMoveSelected?.call(move.uci);
        }
      },
      onMoveHovered: (idx, anchor) {
        final fen = fenAfterMoves(afterFirstMove, sanMoves, idx);
        final uci = idx < continuationUci.length ? continuationUci[idx] : null;
        boardPreview!.setPreview(
          fen,
          moves: sanMoves.sublist(0, idx + 1),
          target: BoardPreviewTarget.floating,
          lastMoveUci: uci,
          anchorGlobal: anchor,
          ownerTag: previewStackKey,
        );
      },
      onHoverExit: () => boardPreview!.clearPreview(),
    );
  }

  void _previewEngineMove(MergedMove move, Offset anchorGlobal) {
    final f = playUciMove(fen, move.uci);
    if (f == null) return;
    boardPreview!.setPreview(
      f,
      moves: [move.san],
      target: BoardPreviewTarget.floating,
      lastMoveUci: move.uci,
      anchorGlobal: anchorGlobal,
      ownerTag: previewStackKey,
    );
  }
}
