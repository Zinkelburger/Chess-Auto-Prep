/// Inline move text with hover-to-preview board functionality.
///
/// Renders a list of SAN moves with move numbers as a single [Text.rich]
/// paragraph — one render object per line list, so hundreds of rows stay
/// cheap to build. On hover, computes the FEN at that move and triggers a
/// floating board preview via [BoardPreviewController].
///
/// Used by: [LinesPreviewPanel], [LineItemRow], PGN Viewer line browser.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/board_preview_controller.dart';
import '../utils/chess_utils.dart' show fenAfterMoves;

/// Compact inline move text with optional hover board preview.
class HoverableMoveChips extends StatefulWidget {
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

  /// Called when a move is tapped (index into [moves]).
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
  State<HoverableMoveChips> createState() => _HoverableMoveChipsState();
}

class _HoverableMoveChipsState extends State<HoverableMoveChips> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  TapGestureRecognizer? _tapRecognizerFor(int index) {
    final onTap = widget.onMoveTapped;
    if (onTap == null) return null;
    final recognizer = TapGestureRecognizer()..onTap = () => onTap(index);
    _recognizers.add(recognizer);
    return recognizer;
  }

  void _onEnterMove(PointerEnterEvent event, int index) {
    final fen = fenAfterMoves(widget.startFen, widget.moves, index);
    widget.boardPreview!.setPreview(
      fen,
      moves: widget.moves.sublist(0, index + 1),
      target: BoardPreviewTarget.floating,
      // Anchor at the pointer, just below the hovered move text.
      anchorGlobal: event.position + Offset(0, widget.fontSize),
      ownerTag: widget.ownerTag,
    );
  }

  @override
  Widget build(BuildContext context) {
    final moves = widget.moves;
    if (moves.isEmpty) return const SizedBox.shrink();

    _disposeRecognizers();

    final theme = Theme.of(context);
    final defaultColor = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final numColor = theme.colorScheme.onSurface.withValues(alpha: 0.45);
    final hlColor = widget.highlightColor ?? theme.colorScheme.primary;

    final hasHover = widget.boardPreview != null;
    final hasTap = widget.onMoveTapped != null;
    final end = moves.length.clamp(0, widget.maxMoves);

    final spans = <InlineSpan>[];
    for (int i = 0; i < end; i++) {
      final ply = widget.startPly + i;
      final isHighlighted = i < widget.highlightDepth;
      // Move number is fused with the white move ("3.e4") so wrapping never
      // separates them.
      final numberPrefix = ply % 2 == 0 ? '${(ply ~/ 2) + 1}.' : '';
      if (numberPrefix.isNotEmpty) {
        spans.add(
          TextSpan(
            text: numberPrefix,
            style: TextStyle(
              fontSize: widget.fontSize,
              color: numColor,
              fontFamily: 'monospace',
              height: 1.5,
            ),
          ),
        );
      }
      spans.add(
        TextSpan(
          text: moves[i],
          style: TextStyle(
            fontSize: widget.fontSize,
            fontFamily: 'monospace',
            color: isHighlighted ? hlColor : defaultColor,
            fontWeight: isHighlighted ? FontWeight.bold : FontWeight.normal,
            backgroundColor: isHighlighted
                ? hlColor.withValues(alpha: 0.25)
                : null,
            height: 1.5,
          ),
          recognizer: _tapRecognizerFor(i),
          onEnter: hasHover ? (event) => _onEnterMove(event, i) : null,
          onExit: hasHover ? (_) => widget.boardPreview!.clearPreview() : null,
          mouseCursor: hasTap ? SystemMouseCursors.click : MouseCursor.defer,
        ),
      );
      if (i < end - 1) {
        spans.add(const TextSpan(text: ' '));
      }
    }

    if (moves.length > widget.maxMoves) {
      spans.add(
        TextSpan(
          text: ' ... +${moves.length - widget.maxMoves}',
          style: TextStyle(
            fontSize: widget.fontSize - 1,
            color: numColor,
            fontStyle: FontStyle.italic,
            height: 1.5,
          ),
        ),
      );
    }

    return Text.rich(TextSpan(children: spans));
  }
}
