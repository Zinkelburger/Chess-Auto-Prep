import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Applies reading anchors while the viewport is laying out, so a new move
/// never paints for one frame at the previous move's scroll offset.
class PgnReadingScrollController extends ScrollController {
  final double Function(double viewportDimension) resolveAnchor;
  bool _anchorPending = false;

  PgnReadingScrollController({required this.resolveAnchor});

  void requestAnchor() => _anchorPending = true;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _ReadingScrollPosition(
    controller: this,
    physics: physics,
    context: context,
    oldPosition: oldPosition,
  );
}

class _ReadingScrollPosition extends ScrollPositionWithSingleContext {
  final PgnReadingScrollController controller;
  bool _applyingAnchor = false;
  bool _disposed = false;

  _ReadingScrollPosition({
    required this.controller,
    required super.physics,
    required super.context,
    super.oldPosition,
  }) : super(initialPixels: 0);

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    _applyingAnchor = controller._anchorPending;
    if (_applyingAnchor) {
      controller._anchorPending = false;
      final offset = controller
          .resolveAnchor(viewportDimension)
          .clamp(minScrollExtent, maxScrollExtent);
      correctBy(offset - pixels);
    }
    try {
      final accepted = super.applyContentDimensions(
        minScrollExtent,
        maxScrollExtent,
      );
      if (_applyingAnchor && activity!.isScrolling) {
        final previousActivity = activity;
        // End any wheel/fling animation before the next frame can pull the
        // reader away. Scroll-end notifications must wait until layout ends.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_disposed && identical(activity, previousActivity)) goIdle();
        });
      }
      return accepted;
    } finally {
      _applyingAnchor = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    // A reading request already chose the offset for the new document size.
    return _applyingAnchor ||
        super.correctForNewDimensions(oldPosition, newPosition);
  }
}

/// Forces the containing viewport to lay out even if only the anchor setting
/// changed and the document retained exactly the same dimensions.
class PgnReadingAnchorLayout extends SingleChildRenderObjectWidget {
  final int revision;

  const PgnReadingAnchorLayout({
    super.key,
    required this.revision,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _AnchorLayout(revision);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    final layout = renderObject as _AnchorLayout;
    if (layout.revision != revision) {
      layout.revision = revision;
      layout.markNeedsLayout();
    }
  }
}

class _AnchorLayout extends RenderProxyBox {
  int revision;
  _AnchorLayout(this.revision);
}
