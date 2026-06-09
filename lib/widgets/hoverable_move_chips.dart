/// Inline move chips with hover-to-preview board functionality.
///
/// Renders a list of SAN moves as compact chips/spans with move numbers.
/// On hover, computes the FEN at that move and triggers a floating board
/// preview via [BoardPreviewController].
///
/// Used by: [LinesPreviewPanel], [LineItemRow], PGN Viewer line browser.
library;

import 'package:flutter/material.dart';

import '../core/board_preview_controller.dart';
import '../utils/chess_utils.dart' show fenAfterMoves;

/// Compact inline move chips with optional hover board preview.
class HoverableMoveChips extends StatelessWidget {
  /// SAN moves to display.
  final List<String> moves;

  /// FEN of the position before the first move in [moves].
  final String startFen;

  /// Maximum number of moves to render (default 8).
  final int maxMoves;

  /// Index offset if [moves] starts partway through a game (default 0).
  /// Used to compute correct move numbers (ply-based).
  final int startPly;

  /// Font size for move text.
  final double fontSize;

  /// Optional: highlight moves up to this depth (0-indexed exclusive).
  final int highlightDepth;

  /// Color for highlighted (matched) moves.
  final Color? highlightColor;

  /// Board preview controller for hover previews. If null, no hover preview.
  final BoardPreviewController? boardPreview;

  /// Opaque tag identifying which pane owns the preview overlay.
  final Object? ownerTag;

  /// Called when a move chip is tapped (index into [moves]).
  final ValueChanged<int>? onMoveTapped;

  const HoverableMoveChips({
    super.key,
    required this.moves,
    this.startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    this.maxMoves = 8,
    this.startPly = 0,
    this.fontSize = 11,
    this.highlightDepth = 0,
    this.highlightColor,
    this.boardPreview,
    this.ownerTag,
    this.onMoveTapped,
  });

  @override
  Widget build(BuildContext context) {
    if (moves.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final defaultColor = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final numColor = theme.colorScheme.onSurface.withValues(alpha: 0.45);
    final hlColor = highlightColor ?? theme.colorScheme.primary;

    final end = moves.length.clamp(0, maxMoves);

    return Wrap(
      spacing: 2,
      runSpacing: 2,
      children: [
        for (int i = 0; i < end; i++) ...[
          if ((startPly + i) % 2 == 0)
            Text(
              '${((startPly + i) ~/ 2) + 1}.',
              style: TextStyle(
                fontSize: fontSize,
                color: numColor,
                fontFamily: 'monospace',
              ),
            ),
          _MoveChip(
            san: moves[i],
            index: i,
            startFen: startFen,
            moves: moves,
            fontSize: fontSize,
            isHighlighted: i < highlightDepth,
            defaultColor: defaultColor,
            highlightColor: hlColor,
            boardPreview: boardPreview,
            ownerTag: ownerTag,
            onTap: onMoveTapped,
          ),
        ],
        if (moves.length > maxMoves)
          Text(
            '... +${moves.length - maxMoves}',
            style: TextStyle(
              fontSize: fontSize - 1,
              color: numColor,
              fontStyle: FontStyle.italic,
            ),
          ),
      ],
    );
  }
}

class _MoveChip extends StatelessWidget {
  final String san;
  final int index;
  final String startFen;
  final List<String> moves;
  final double fontSize;
  final bool isHighlighted;
  final Color defaultColor;
  final Color highlightColor;
  final BoardPreviewController? boardPreview;
  final Object? ownerTag;
  final ValueChanged<int>? onTap;

  const _MoveChip({
    required this.san,
    required this.index,
    required this.startFen,
    required this.moves,
    required this.fontSize,
    required this.isHighlighted,
    required this.defaultColor,
    required this.highlightColor,
    this.boardPreview,
    this.ownerTag,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasHover = boardPreview != null;
    final hasTap = onTap != null;

    Widget chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: isHighlighted
          ? BoxDecoration(
              color: highlightColor.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(2),
            )
          : null,
      child: Text(
        san,
        style: TextStyle(
          fontSize: fontSize,
          fontFamily: 'monospace',
          color: isHighlighted ? highlightColor : defaultColor,
          fontWeight: isHighlighted ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );

    if (!hasHover && !hasTap) return chip;

    return Builder(
      builder: (anchorContext) {
        return MouseRegion(
          cursor: hasTap ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: hasHover
              ? (_) {
                  final box =
                      anchorContext.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final anchor = box.localToGlobal(
                    Offset(box.size.width / 2, box.size.height),
                  );
                  final fen = fenAfterMoves(startFen, moves, index);
                  boardPreview!.setPreview(
                    fen,
                    moves: moves.sublist(0, index + 1),
                    target: BoardPreviewTarget.floating,
                    anchorGlobal: anchor,
                    ownerTag: ownerTag,
                  );
                }
              : null,
          onExit: hasHover ? (_) => boardPreview!.clearPreview() : null,
          child: GestureDetector(
            onTap: hasTap ? () => onTap!(index) : null,
            behavior: HitTestBehavior.opaque,
            child: chip,
          ),
        );
      },
    );
  }
}
