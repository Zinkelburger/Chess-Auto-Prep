import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../theme/app_colors.dart';
import 'pgn_reading_pane.dart';

/// One move and its explanation. The same heading stays at the top while a
/// long note is being read; it stops at the end of that note. No text is copied
/// into an overlay, and the rest of the document keeps its natural height.
class PgnReadingPassage extends StatelessWidget {
  final bool active;
  final List<Widget> children;

  const PgnReadingPassage({
    super.key,
    required this.active,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return _StickyPassage(
      position: Scrollable.maybeOf(context)?.position,
      active: active,
      heading: ColoredBox(
        color: PgnReadingPane.surfaceOf(context),
        child: children.first,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children.skip(1).toList(),
      ),
    );
  }
}

class _StickyPassage extends MultiChildRenderObjectWidget {
  final ScrollPosition? position;
  final bool active;

  _StickyPassage({
    required this.position,
    required this.active,
    required Widget heading,
    required Widget body,
  }) : super(children: [body, heading]);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPassage(position, active);

  @override
  void updateRenderObject(BuildContext context, _RenderPassage renderObject) {
    renderObject.update(position, active);
  }
}

class _PassageParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderPassage extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  // This wrapper owns passage spacing; child prose need not add another
  // paragraph-sized margin around the same move and explanation.
  static const _topPadding = 6.0;
  static const _headingGap = 4.0;
  static const _bottomPadding = 8.0;

  ScrollPosition? _position;
  bool _active;
  _RenderPassage(this._position, this._active);

  void update(ScrollPosition? position, bool active) {
    if (_position != position) {
      if (attached) _position?.removeListener(_scrollChanged);
      _position = position;
      if (attached) _position?.addListener(_scrollChanged);
    }
    _active = active;
    markNeedsPaint();
  }

  void _scrollChanged() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _position?.addListener(_scrollChanged);
  }

  @override
  void detach() {
    _position?.removeListener(_scrollChanged);
    super.detach();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _PassageParentData();
    }
  }

  @override
  void performLayout() {
    final heading = lastChild!;
    final body = firstChild!;
    final childConstraints = BoxConstraints.tightFor(
      width: constraints.maxWidth,
    );
    heading.layout(childConstraints, parentUsesSize: true);
    body.layout(childConstraints, parentUsesSize: true);
    (body.parentData! as BoxParentData).offset = Offset(
      0,
      _topPadding + heading.size.height + _headingGap,
    );
    (heading.parentData! as BoxParentData).offset = const Offset(
      0,
      _topPadding,
    );
    size = constraints.constrain(
      Size(
        constraints.maxWidth,
        _topPadding +
            heading.size.height +
            _headingGap +
            body.size.height +
            _bottomPadding,
      ),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    var pinned = 0.0;
    if (_active && _position != null) {
      final viewport = RenderAbstractViewport.maybeOf(this);
      if (viewport != null) {
        final top = viewport.getOffsetToReveal(this, 0).offset + _topPadding;
        pinned = (_position!.pixels - top).clamp(
          0.0,
          size.height - lastChild!.size.height - _topPadding,
        );
      }
    }
    (lastChild!.parentData! as BoxParentData).offset = Offset(
      0,
      _topPadding + pinned,
    );
    defaultPaint(context, offset);
    if (_active) {
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            offset.dx - 17,
            offset.dy + _topPadding + 4 + pinned,
            3,
            25,
          ),
          const Radius.circular(2),
        ),
        Paint()..color = AppColors.pgnMoveCurrent,
      );
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = (child.parentData! as BoxParentData).offset;
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }
}
