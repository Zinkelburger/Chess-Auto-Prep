/// Hoverable eye icon that shows a floating chess board preview.
///
/// Used next to position filter inputs so users can verify their FEN or move
/// sequence visually without applying the filter.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../utils/best_effort_position.dart';
import 'chess_board_widget.dart';

/// Small eye icon that shows a floating board preview on hover.
///
/// [inputGetter] is called on each hover to obtain the current text input;
/// [bestEffortPositionFromInput] resolves it to a renderable position.
class PositionPreviewIcon extends StatefulWidget {
  final String Function() inputGetter;

  const PositionPreviewIcon({super.key, required this.inputGetter});

  @override
  State<PositionPreviewIcon> createState() => _PositionPreviewIconState();
}

class _PositionPreviewIconState extends State<PositionPreviewIcon> {
  OverlayEntry? _overlayEntry;

  static const double _boardSize = 200;
  static const double _anchorGap = 8;

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  void _showOverlay() {
    final position = bestEffortPositionFromInput(widget.inputGetter());
    if (position == null) return;

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final anchor = box.localToGlobal(
      Offset(box.size.width / 2, box.size.height),
    );

    _overlayEntry?.remove();
    _overlayEntry = OverlayEntry(
      builder: (_) => _buildBoard(position, anchor),
    );
    overlay.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  Widget _buildBoard(Position position, Offset anchor) {
    final screenSize = MediaQuery.of(context).size;
    var left = anchor.dx - _boardSize / 2;
    var top = anchor.dy + _anchorGap;

    left = left.clamp(
        0.0, (screenSize.width - _boardSize).clamp(0.0, double.infinity));
    if (top + _boardSize > screenSize.height - 8) {
      top = anchor.dy - _boardSize - _anchorGap - 24;
    }
    if (top < 0) top = 0;

    return Positioned(
      left: left,
      top: top,
      width: _boardSize,
      height: _boardSize,
      child: IgnorePointer(
        child: Material(
          elevation: 8,
          shadowColor: Colors.black54,
          borderRadius: BorderRadius.circular(4),
          clipBehavior: Clip.antiAlias,
          child: ChessBoardWidget(
            position: position,
            flipped: false,
            enableUserMoves: false,
            onMove: null,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: MouseRegion(
        onEnter: (_) => _showOverlay(),
        onExit: (_) => _removeOverlay(),
        child: Tooltip(
          message: 'Preview position',
          child: Icon(
            Icons.visibility_outlined,
            size: 16,
            color: Colors.grey[400],
          ),
        ),
      ),
    );
  }
}
