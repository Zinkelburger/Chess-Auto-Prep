import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' show Move, Side;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../ui/theme.dart';

/// What the small board under a hovered engine move shows: the position
/// after the move, the move itself for the highlight, and where on the
/// screen the move is so the board can sit under it.
final class LinePreview {
  const LinePreview({
    required this.fen,
    required this.lastMove,
    required this.anchor,
  });

  final Fen fen;

  /// As UCI.
  final String lastMove;

  /// The bottom centre of the hovered move, in screen coordinates.
  final Offset anchor;
}

/// Floats a small board over everything while [preview] has one to show,
/// the way the old app previewed engine lines: centred under the hovered
/// move, or above it when there is no room below. It takes no pointer, so
/// the move under it keeps the hover. [child] is laid out as if the board
/// were not there.
class LinePreviewOverlay extends StatefulWidget {
  const LinePreviewOverlay({
    super.key,
    required this.preview,
    required this.orientation,
    required this.child,
  });

  final ValueListenable<LinePreview?> preview;
  final Side orientation;
  final Widget child;

  @override
  State<LinePreviewOverlay> createState() => _LinePreviewOverlayState();
}

class _LinePreviewOverlayState extends State<LinePreviewOverlay> {
  final _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    widget.preview.addListener(_follow);
  }

  @override
  void didUpdateWidget(LinePreviewOverlay old) {
    super.didUpdateWidget(old);
    if (old.preview != widget.preview) {
      old.preview.removeListener(_follow);
      widget.preview.addListener(_follow);
    }
  }

  @override
  void dispose() {
    widget.preview.removeListener(_follow);
    super.dispose();
  }

  void _follow() {
    if (!mounted) return;
    if (widget.preview.value == null) {
      _portal.hide();
    } else if (_portal.isShowing) {
      setState(() {});
    } else {
      _portal.show();
    }
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _board,
      child: widget.child,
    );
  }

  Widget _board(BuildContext context) {
    final preview = widget.preview.value;
    if (preview == null) return const SizedBox.shrink();
    final at = _place(preview.anchor, MediaQuery.sizeOf(context));
    return Positioned(
      left: at.dx,
      top: at.dy,
      width: previewBoardSize,
      height: previewBoardSize,
      child: IgnorePointer(
        child: Material(
          elevation: 8,
          shadowColor: Theme.of(context).colorScheme.shadow,
          borderRadius: BorderRadius.circular(4),
          clipBehavior: Clip.antiAlias,
          child: StaticChessboard(
            size: previewBoardSize,
            orientation: widget.orientation,
            fen: preview.fen.value,
            lastMove: Move.parse(preview.lastMove),
            settings: BoardTheme.of(context).previewSettings,
          ),
        ),
      ),
    );
  }
}

/// Where the board's top left corner goes: centred under [anchor], kept
/// inside the window, and flipped above the anchor when it would run off
/// the bottom.
Offset _place(Offset anchor, Size window) {
  const size = previewBoardSize;
  final left = (anchor.dx - size / 2).clamp(
    0.0,
    (window.width - size).clamp(0.0, double.infinity),
  );
  var top = anchor.dy + previewBoardGap;
  if (top + size > window.height - Space.s) {
    top = anchor.dy - size - previewBoardGap;
  }
  return Offset(left, top < 0 ? 0 : top);
}
