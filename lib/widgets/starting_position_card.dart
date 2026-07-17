/// Prominent "this is the position we start from" banner shared by every
/// mode that consumes the board position (Generate, Build by Playing, ...).
///
/// Shows a static mini board plus the moves that lead to it, so the user can
/// see at a glance exactly where the run will begin — the board position is
/// an input the user must be able to verify, never an invisible default.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../constants/chess_constants.dart';
import '../services/generation/pgn_export.dart';
import '../theme/app_colors.dart';
import 'chess_board_widget.dart';

class StartingPositionCard extends StatelessWidget {
  const StartingPositionCard({
    super.key,
    required this.label,
    required this.fen,
    required this.moveSans,
    this.flipped = false,
  });

  /// Small all-caps heading, e.g. 'GENERATING FROM' or 'SESSION STARTS FROM'.
  final String label;

  /// Position the run starts from.
  final String fen;

  /// SAN moves from the repertoire start to [fen]; empty at the start itself.
  final List<String> moveSans;

  /// Orient the preview from Black's side (black repertoires).
  final bool flipped;

  static const double _boardSize = 108;

  bool get _isStandardStart =>
      fen.split(' ').first == kStandardStartFen.split(' ').first;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final movesText = moveSans.isNotEmpty
        ? movesToPgnMoveText(moveSans)
        : _isStandardStart
        ? 'Initial position — no moves played'
        : 'Repertoire starting position';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: primary, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _boardPreview(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                    color: primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  movesText,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _boardPreview() {
    final Position position;
    try {
      position = Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      return const SizedBox(
        width: _boardSize,
        height: _boardSize,
        child: Icon(
          Icons.broken_image_outlined,
          size: 24,
          color: AppColors.onSurfaceDim,
        ),
      );
    }
    return SizedBox(
      width: _boardSize,
      height: _boardSize,
      // RepaintBoundary keeps the 64-square raster out of ancestor repaints.
      child: RepaintBoundary(
        child: IgnorePointer(
          child: ChessBoardWidget(
            position: position,
            flipped: flipped,
            enableUserMoves: false,
          ),
        ),
      ),
    );
  }
}
