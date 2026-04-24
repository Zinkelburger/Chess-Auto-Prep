import 'package:flutter/material.dart';

import '../controllers/eval_tree_controller.dart';
import '../models/eval_tree_snapshot.dart';
import '../services/eval_tree_layout_engine.dart';
import 'eval_tree_node_chip.dart';

class EvalTreeViewport extends StatefulWidget {
  final EvalTreeSnapshot snapshot;
  final EvalTreeController controller;
  final EvalTreeLayoutFrame frame;

  const EvalTreeViewport({
    super.key,
    required this.snapshot,
    required this.controller,
    required this.frame,
  });

  @override
  State<EvalTreeViewport> createState() => _EvalTreeViewportState();
}

class _EvalTreeViewportState extends State<EvalTreeViewport> {
  static const double _minScale = 0.25;
  static const double _maxScale = 3.0;
  static const Duration _exitDuration = Duration(milliseconds: 200);
  int _lastHandledFocusRequestId = -1;
  Size? _lastViewportSize;

  final Map<int, _ExitingNode> _exitingNodes = {};

  @override
  void didUpdateWidget(covariant EvalTreeViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldNodeIds = oldWidget.frame.nodesById.keys.toSet();
    final newNodeIds = widget.frame.nodesById.keys.toSet();
    final removed = oldNodeIds.difference(newNodeIds);

    for (final nodeId in removed) {
      final layoutNode = oldWidget.frame.nodesById[nodeId]!;
      final snapshotNode = oldWidget.snapshot.tryNode(nodeId);
      if (snapshotNode == null) continue;
      _exitingNodes[nodeId] = _ExitingNode(
        layoutNode: layoutNode,
        snapshotNode: snapshotNode,
        snapshot: oldWidget.snapshot,
      );
    }
    _exitingNodes.removeWhere((id, _) => newNodeIds.contains(id));
    _applyPendingFocusIfPossible();
  }

  void _onExitComplete(int nodeId) {
    if (!mounted) return;
    setState(() => _exitingNodes.remove(nodeId));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.frame.nodesById.isEmpty && _exitingNodes.isEmpty) {
      return Center(
        child: Text(
          'No nodes to display',
          style: TextStyle(color: Colors.grey[600], fontSize: 13),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
          return const SizedBox.shrink();
        }

        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        _lastViewportSize = viewportSize;
        _scheduleFocusIfNeeded(viewportSize);

        return ClipRect(
          child: InteractiveViewer(
            transformationController:
                widget.controller.transformationController,
            constrained: false,
            minScale: _minScale,
            maxScale: _maxScale,
            boundaryMargin: const EdgeInsets.all(96),
            child: SizedBox(
              width: widget.frame.canvasSize.width,
              height: widget.frame.canvasSize.height,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _EvalTreeEdgePainter(
                        snapshot: widget.snapshot,
                        frame: widget.frame,
                      ),
                    ),
                  ),
                  for (final entry in _exitingNodes.entries)
                    Positioned(
                      left: entry.value.layoutNode.position.dx,
                      top: entry.value.layoutNode.position.dy,
                      child: _FadingNodeChip(
                        key: ValueKey('eval-tree-exit-${entry.key}'),
                        duration: _exitDuration,
                        onComplete: () => _onExitComplete(entry.key),
                        child: IgnorePointer(
                          child: EvalTreeNodeChip(
                            snapshot: entry.value.snapshot,
                            node: entry.value.snapshotNode,
                            layoutNode: entry.value.layoutNode,
                            metricDisplayMode:
                                widget.controller.metricDisplayMode,
                            onTap: () {},
                          ),
                        ),
                      ),
                    ),
                  for (final layoutNode in widget.frame.nodes)
                    Positioned(
                      left: layoutNode.position.dx,
                      top: layoutNode.position.dy,
                      child: EvalTreeNodeChip(
                        key: ValueKey('eval-tree-node-${layoutNode.nodeId}'),
                        snapshot: widget.snapshot,
                        node: widget.snapshot.node(layoutNode.nodeId),
                        layoutNode: layoutNode,
                        metricDisplayMode: widget.controller.metricDisplayMode,
                        onTap: () =>
                            widget.controller.selectNode(layoutNode.nodeId),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _scheduleFocusIfNeeded(Size viewportSize) {
    if (_lastHandledFocusRequestId == widget.controller.focusRequestId) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyFocus(viewportSize);
    });
  }

  void _applyPendingFocusIfPossible() {
    if (_lastHandledFocusRequestId == widget.controller.focusRequestId) {
      return;
    }
    final viewportSize = _lastViewportSize;
    if (viewportSize == null ||
        viewportSize.width <= 0 ||
        viewportSize.height <= 0) {
      return;
    }
    _applyFocus(viewportSize);
  }

  void _applyFocus(Size viewportSize) {
    final targetNodeId = widget.controller.focusTargetNodeId;
    final requestId = widget.controller.focusRequestId;
    if (targetNodeId == null) {
      _lastHandledFocusRequestId = requestId;
      return;
    }

    final layoutNode = widget.frame.tryNode(targetNodeId) ??
        widget.frame.tryNode(widget.frame.selectedNodeId) ??
        widget.frame.tryNode(widget.frame.rootNodeId);
    if (layoutNode == null) {
      _lastHandledFocusRequestId = requestId;
      widget.controller.clearFocusRequest();
      return;
    }

    final currentScale = widget.controller.transformationController.value
        .getMaxScaleOnAxis()
        .clamp(_minScale, _maxScale);
    final scale = widget.controller.focusResetZoom ? 1.0 : currentScale;
    final nodeCenter = layoutNode.rect.center;
    final translation = Offset(
      viewportSize.width / 2 - nodeCenter.dx * scale,
      viewportSize.height / 2 - nodeCenter.dy * scale,
    );
    widget.controller.transformationController.value = Matrix4.identity()
      ..translateByDouble(translation.dx, translation.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);

    _lastHandledFocusRequestId = requestId;
    widget.controller.clearFocusRequest();
  }
}

class _EvalTreeEdgePainter extends CustomPainter {
  final EvalTreeSnapshot snapshot;
  final EvalTreeLayoutFrame frame;

  const _EvalTreeEdgePainter({
    required this.snapshot,
    required this.frame,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in frame.edges) {
      final source = frame.tryNode(edge.sourceNodeId);
      final destination = frame.tryNode(edge.destinationNodeId);
      if (source == null || destination == null) continue;

      final childNode = snapshot.node(edge.destinationNodeId);
      final paint = Paint()
        ..color =
            childNode.isRepertoireMove ? Colors.blue[400]! : Colors.grey[700]!
        ..strokeWidth = childNode.isRepertoireMove ? 2.5 : 1.0
        ..style = PaintingStyle.stroke;

      final sourceCenter = Offset(source.rect.center.dx, source.rect.bottom);
      final destinationCenter =
          Offset(destination.rect.center.dx, destination.rect.top);
      final midY = (sourceCenter.dy + destinationCenter.dy) / 2;
      final path = Path()
        ..moveTo(sourceCenter.dx, sourceCenter.dy)
        ..lineTo(sourceCenter.dx, midY)
        ..lineTo(destinationCenter.dx, midY)
        ..lineTo(destinationCenter.dx, destinationCenter.dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _EvalTreeEdgePainter oldDelegate) {
    return oldDelegate.frame != frame || oldDelegate.snapshot != snapshot;
  }
}

class _ExitingNode {
  final EvalTreeLayoutNode layoutNode;
  final EvalTreeNodeSnapshot snapshotNode;
  final EvalTreeSnapshot snapshot;

  _ExitingNode({
    required this.layoutNode,
    required this.snapshotNode,
    required this.snapshot,
  });
}

class _FadingNodeChip extends StatefulWidget {
  final Duration duration;
  final VoidCallback onComplete;
  final Widget child;

  const _FadingNodeChip({
    super.key,
    required this.duration,
    required this.onComplete,
    required this.child,
  });

  @override
  State<_FadingNodeChip> createState() => _FadingNodeChipState();
}

class _FadingNodeChipState extends State<_FadingNodeChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          widget.onComplete();
        }
      })
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeOut),
      ),
      child: widget.child,
    );
  }
}
