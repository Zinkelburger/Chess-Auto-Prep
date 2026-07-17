/// Draggable divider for resizable Edit context panes.
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

enum EditContextSplitAxis { horizontal, vertical }

class EditContextSplitHandle extends StatefulWidget {
  final EditContextSplitAxis axis;
  final ValueChanged<double> onDrag;

  const EditContextSplitHandle({
    super.key,
    required this.axis,
    required this.onDrag,
  });

  @override
  State<EditContextSplitHandle> createState() => _EditContextSplitHandleState();
}

class _EditContextSplitHandleState extends State<EditContextSplitHandle> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final isVertical = widget.axis == EditContextSplitAxis.vertical;

    return GestureDetector(
      onHorizontalDragStart: isVertical ? null : (_) => _setDragging(true),
      onHorizontalDragUpdate: isVertical
          ? null
          : (d) => widget.onDrag(d.delta.dx),
      onHorizontalDragEnd: isVertical ? null : (_) => _setDragging(false),
      onHorizontalDragCancel: isVertical ? null : () => _setDragging(false),
      onVerticalDragStart: isVertical ? (_) => _setDragging(true) : null,
      onVerticalDragUpdate: isVertical
          ? (d) => widget.onDrag(d.delta.dy)
          : null,
      onVerticalDragEnd: isVertical ? (_) => _setDragging(false) : null,
      onVerticalDragCancel: isVertical ? () => _setDragging(false) : null,
      child: MouseRegion(
        cursor: isVertical
            ? SystemMouseCursors.resizeRow
            : SystemMouseCursors.resizeColumn,
        child: isVertical ? _verticalHandle() : _horizontalHandle(),
      ),
    );
  }

  void _setDragging(bool v) {
    if (_dragging == v) return;
    setState(() => _dragging = v);
  }

  Widget _verticalHandle() {
    return Container(
      height: 8,
      color: Colors.transparent,
      child: Center(child: _grip(40, 3)),
    );
  }

  Widget _horizontalHandle() {
    return Container(
      width: 8,
      color: Colors.transparent,
      child: Center(child: _grip(3, 40)),
    );
  }

  Widget _grip(double width, double height) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: _dragging ? width * 1.4 : width,
      height: _dragging ? height * 1.4 : height,
      decoration: BoxDecoration(
        color: _dragging ? AppColors.accent : AppColors.onSurfaceDim,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
