/// A single move row in the live opening explorer.
///
/// Layout mirrors the familiar explorer table: SAN on the left, the number
/// of games in the middle, and a white/grey/black result bar on the right
/// showing the win/draw/loss split for that move. Clicking the row plays the
/// move; the trailing "+" adds it to the repertoire.
library;

import 'package:flutter/material.dart';

import '../../models/explorer_response.dart';
import '../../models/opening_tree.dart';
import '../../theme/app_colors.dart';
import '../opening_tree/win_draw_loss_bar.dart';

class ExplorerMoveRow extends StatefulWidget {
  const ExplorerMoveRow({
    super.key,
    required this.move,
    required this.onPlay,
    this.onAdd,
    this.inRepertoire = false,
  });

  final ExplorerMove move;
  final VoidCallback onPlay;

  /// When non-null, shows a "+" to add the move to the repertoire.
  final VoidCallback? onAdd;

  /// Whether this move already exists in the repertoire (styles the SAN).
  final bool inRepertoire;

  @override
  State<ExplorerMoveRow> createState() => _ExplorerMoveRowState();
}

class _ExplorerMoveRowState extends State<ExplorerMoveRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final move = widget.move;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPlay,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _hovered ? theme.colorScheme.surfaceContainerHighest : null,
            // Frequency "heat" matching the repertoire tree rows: a heavier
            // left-anchored wash for more-played moves.
            gradient: _hovered
                ? null
                : LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    stops: [
                      (move.playFraction).clamp(0.0, 1.0),
                      (move.playFraction).clamp(0.0, 1.0),
                    ],
                    colors: [
                      Colors.white.withValues(alpha: 0.05),
                      Colors.transparent,
                    ],
                  ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 52,
                child: Text(
                  move.san,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: widget.inRepertoire ? AppColors.evalPositive : null,
                  ),
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  _formatCount(move.total),
                  style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                ),
              ),
              Expanded(
                child: WinDrawLossBar(
                  wins: move.white,
                  draws: move.draws,
                  losses: move.black,
                  perspective: WdlPerspective.whiteBlack,
                  height: 15,
                ),
              ),
              SizedBox(
                width: 34,
                child: widget.onAdd != null && (_hovered || widget.inRepertoire)
                    ? IconButton(
                        icon: Icon(
                          widget.inRepertoire ? Icons.check : Icons.add,
                          size: 15,
                        ),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        tooltip: widget.inRepertoire
                            ? 'Already in repertoire'
                            : 'Add ${move.san} to repertoire',
                        onPressed: widget.inRepertoire ? null : widget.onAdd,
                      )
                    : Text(
                        move.formattedPlayRate,
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Compact game counts: 1234 → "1.2k", 1_200_000 → "1.2M".
  static String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}
