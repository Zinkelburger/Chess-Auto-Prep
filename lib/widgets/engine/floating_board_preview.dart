/// Cursor-following mini board overlay for engine PV hover preview.
///
/// Uses [Overlay] so the board floats above all widgets and is not clipped
/// by parent containers.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../services/board_preview_controller.dart';
import '../../utils/chess_utils.dart' show uciHighlightSquares;
import '../chess_board_widget.dart';

class FloatingBoardPreview extends StatefulWidget {
  final GlobalKey stackKey;
  final BoardPreviewController controller;
  final bool flipped;

  /// Only render when [controller.ownerTag] matches this value.
  final Object? ownerTag;

  static const double boardSize = 200;
  static const double anchorGap = 6;

  const FloatingBoardPreview({
    super.key,
    required this.stackKey,
    required this.controller,
    required this.flipped,
    this.ownerTag,
  });

  @override
  State<FloatingBoardPreview> createState() => _FloatingBoardPreviewState();
}

class _FloatingBoardPreviewState extends State<FloatingBoardPreview> {
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onPreviewChanged);
  }

  @override
  void didUpdateWidget(covariant FloatingBoardPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onPreviewChanged);
      widget.controller.addListener(_onPreviewChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onPreviewChanged);
    _removeOverlay();
    super.dispose();
  }

  void _onPreviewChanged() {
    final ctrl = widget.controller;
    final shouldShow = ctrl.isPreview &&
        ctrl.target == BoardPreviewTarget.floating &&
        ctrl.previewFen != null &&
        ctrl.anchorGlobal != null &&
        (widget.ownerTag == null || ctrl.ownerTag == widget.ownerTag);

    if (shouldShow) {
      _showOverlay();
    } else {
      _removeOverlay();
    }
  }

  void _showOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = OverlayEntry(builder: (_) => _buildBoard());
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  Widget _buildBoard() {
    final ctrl = widget.controller;
    if (ctrl.previewFen == null || ctrl.anchorGlobal == null) {
      return const SizedBox.shrink();
    }

    final screenSize = MediaQuery.of(context).size;
    const bs = FloatingBoardPreview.boardSize;
    const gap = FloatingBoardPreview.anchorGap;
    final anchor = ctrl.anchorGlobal!;

    var left = anchor.dx - bs / 2;
    var top = anchor.dy + gap;

    left = left.clamp(0.0, (screenSize.width - bs).clamp(0.0, double.infinity));

    // If the board would go below the screen, flip it above the cursor.
    if (top + bs > screenSize.height - 8) {
      top = anchor.dy - bs - gap;
    }
    if (top < 0) top = 0;

    Position position;
    try {
      position = Chess.fromSetup(Setup.parseFen(ctrl.previewFen!));
    } catch (_) {
      return const SizedBox.shrink();
    }

    final highlights = ctrl.lastMoveUci != null
        ? uciHighlightSquares(ctrl.lastMoveUci!)
        : const <String>{};

    return Positioned(
      left: left,
      top: top,
      width: bs,
      height: bs,
      child: IgnorePointer(
        child: Material(
          elevation: 8,
          shadowColor: Colors.black54,
          borderRadius: BorderRadius.circular(4),
          clipBehavior: Clip.antiAlias,
          child: ChessBoardWidget(
            key: ValueKey(ctrl.previewFen),
            position: position,
            flipped: widget.flipped,
            enableUserMoves: false,
            onMove: null,
            highlightedSquares: highlights,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The overlay handles rendering; this widget is just a lifecycle anchor.
    return const SizedBox.shrink();
  }
}
