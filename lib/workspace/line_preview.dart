import 'dart:async';

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' show Move, Side;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../ui/listening_state.dart';
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

/// Floats a small board over everything while [preview] has one to show:
/// centred under the hovered move, or above it when there is no room below. It
/// takes no pointer, so the move under it keeps the hover. [child] is laid out
/// as if the board were not there.
class LinePreviewOverlay extends StatelessWidget {
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
  Widget build(BuildContext context) => FloatingPreview<LinePreview>(
    preview: preview,
    anchor: (preview) => preview.anchor,
    size: const Size.square(previewBoardSize),
    builder: (context, preview) => StaticChessboard(
      size: previewBoardSize,
      orientation: orientation,
      fen: preview.fen.value,
      lastMove: Move.parse(preview.lastMove),
      settings: BoardTheme.of(context).previewSettings,
    ),
    child: child,
  );
}

/// What a floated board shows while the pointer rests on a move: set once
/// the pointer has stayed [previewDelay] on it, cleared as it leaves. A
/// pane hands it to a [FloatingPreview] and disposes it with itself, which
/// also drops a rest still being timed.
final class HoverPreview<T extends Object> extends ValueNotifier<T?> {
  HoverPreview() : super(null);

  Timer? _settle;

  /// What [shown] answers goes up once the pointer has rested; a [rest] or
  /// [leave] before then replaces it. An answer of null shows nothing.
  void rest(T? Function() shown) {
    _settle?.cancel();
    _settle = Timer(previewDelay, () {
      if (shown() case final preview?) value = preview;
    });
  }

  /// The pointer left: the board goes, and a rest still being timed too.
  void leave() {
    _settle?.cancel();
    value = null;
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }
}

/// Floats what [builder] makes of [preview]'s value, [size] big, over
/// everything while there is one: centred under the point [anchor] gives,
/// or above it when there is no room below, inside a 1px outline. It takes
/// no pointer, so the move under it keeps the hover. [child] is laid out
/// as if it were not there.
class FloatingPreview<T extends Object> extends StatefulWidget {
  const FloatingPreview({
    super.key,
    required this.preview,
    required this.anchor,
    required this.size,
    required this.builder,
    required this.child,
  });

  final ValueListenable<T?> preview;

  /// The bottom centre of the hovered move, in screen coordinates.
  final Offset Function(T value) anchor;
  final Size size;
  final Widget Function(BuildContext context, T value) builder;
  final Widget child;

  @override
  State<FloatingPreview<T>> createState() => _FloatingPreviewState<T>();
}

class _FloatingPreviewState<T extends Object> extends State<FloatingPreview<T>>
    with ListeningState<FloatingPreview<T>> {
  final _portal = OverlayPortalController();

  @override
  Listenable listenableOf(FloatingPreview<T> widget) => widget.preview;

  @override
  void changed() {
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
      overlayChildBuilder: _floating,
      child: widget.child,
    );
  }

  Widget _floating(BuildContext context) {
    final preview = widget.preview.value;
    if (preview == null) return const SizedBox.shrink();
    final size = widget.size;
    final at = _place(widget.anchor(preview), size, MediaQuery.sizeOf(context));
    return Positioned(
      left: at.dx,
      top: at.dy,
      width: size.width,
      height: size.height,
      child: IgnorePointer(
        // Flat, as every surface is: an outline sets it off, not a shadow.
        child: Material(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: BorderSide(color: Theme.of(context).colorScheme.outline),
          ),
          clipBehavior: Clip.antiAlias,
          child: widget.builder(context, preview),
        ),
      ),
    );
  }
}

/// Where the top left corner of something [size] big goes: centred under
/// [anchor], kept inside the window, and flipped above the anchor when it
/// would run off the bottom.
Offset _place(Offset anchor, Size size, Size window) {
  final left = (anchor.dx - size.width / 2).clamp(
    0.0,
    (window.width - size.width).clamp(0.0, double.infinity),
  );
  var top = anchor.dy + previewBoardGap;
  if (top + size.height > window.height - Space.s) {
    top = anchor.dy - size.height - previewBoardGap;
  }
  return Offset(left, top < 0 ? 0 : top);
}
