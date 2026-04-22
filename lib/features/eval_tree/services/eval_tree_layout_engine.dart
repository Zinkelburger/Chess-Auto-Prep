import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controllers/eval_tree_controller.dart';
import '../models/eval_tree_snapshot.dart';

class EvalTreeLayoutConfig {
  final double horizontalGap;
  final double verticalGap;
  final double canvasPadding;
  final double minNodeWidth;
  final double maxNodeWidth;
  final double compactNodeHeight;
  final double expandedNodeHeight;

  const EvalTreeLayoutConfig({
    this.horizontalGap = 28,
    this.verticalGap = 68,
    this.canvasPadding = 32,
    this.minNodeWidth = 56,
    this.maxNodeWidth = 128,
    this.compactNodeHeight = 30,
    this.expandedNodeHeight = 46,
  });
}

class EvalTreeLayoutNode {
  final int nodeId;
  final Offset position;
  final Size size;
  final bool isSelected;

  const EvalTreeLayoutNode({
    required this.nodeId,
    required this.position,
    required this.size,
    required this.isSelected,
  });

  Rect get rect => position & size;
}

class EvalTreeLayoutEdge {
  final int sourceNodeId;
  final int destinationNodeId;

  const EvalTreeLayoutEdge({
    required this.sourceNodeId,
    required this.destinationNodeId,
  });
}

class EvalTreeLayoutFrame {
  final int rootNodeId;
  final int selectedNodeId;
  final bool hitDisplayCap;
  final Size canvasSize;
  final Rect contentBounds;
  final UnmodifiableMapView<int, EvalTreeLayoutNode> nodesById;
  final List<EvalTreeLayoutEdge> edges;

  EvalTreeLayoutFrame({
    required this.rootNodeId,
    required this.selectedNodeId,
    required this.hitDisplayCap,
    required this.canvasSize,
    required this.contentBounds,
    required Map<int, EvalTreeLayoutNode> nodesById,
    required this.edges,
  }) : nodesById = UnmodifiableMapView(Map.unmodifiable(nodesById));

  List<EvalTreeLayoutNode> get nodes => nodesById.values.toList()
    ..sort((a, b) {
      final vertical = a.position.dy.compareTo(b.position.dy);
      if (vertical != 0) return vertical;
      return a.position.dx.compareTo(b.position.dx);
    });

  EvalTreeLayoutNode? tryNode(int nodeId) => nodesById[nodeId];
}

class EvalTreeLayoutEngine {
  static const double nodeHorizontalPadding = 8;
  static const double nodeVerticalPadding = 5;
  static const double nodeTitleFontSize = 13;
  static const double nodeSecondaryFontSize = 11;
  static const String nodeFontFamily = 'monospace';
  static const double _nodeTextWidthBuffer = 4;
  static const TextStyle _nodeTitleMeasureStyle = TextStyle(
    fontSize: nodeTitleFontSize,
    fontWeight: FontWeight.bold,
    fontFamily: nodeFontFamily,
  );
  static const TextStyle _nodeSecondaryMeasureStyle = TextStyle(
    fontSize: nodeSecondaryFontSize,
    fontFamily: nodeFontFamily,
  );

  static EvalTreeLayoutFrame buildFrame(
    EvalTreeSnapshot snapshot,
    EvalTreeController controller, {
    EvalTreeLayoutConfig config = const EvalTreeLayoutConfig(),
  }) {
    final selectedNodeId = controller.selectedNodeId ?? snapshot.rootNodeId;
    final visibleNodeIds =
        _buildVisibleNodeIds(snapshot, controller, selectedNodeId);
    final rootNodeId = controller.showAncestorSpine
        ? _resolveVisibleRootNodeId(snapshot, selectedNodeId, visibleNodeIds)
        : selectedNodeId;
    final visibleChildren = <int, List<int>>{
      for (final nodeId in visibleNodeIds)
        nodeId: [
          for (final childId in snapshot.node(nodeId).childIds)
            if (visibleNodeIds.contains(childId)) childId,
        ],
    };

    final nodeSizes = <int, Size>{
      for (final nodeId in visibleNodeIds)
        nodeId: _estimateNodeSize(
          snapshot,
          snapshot.node(nodeId),
          controller.metricDisplayMode,
          config,
        ),
    };
    final subtreeWidths = <int, double>{};
    _measureSubtreeWidths(
        rootNodeId, visibleChildren, nodeSizes, subtreeWidths, config);

    final positionedNodes = <int, EvalTreeLayoutNode>{};
    _positionNode(
      rootNodeId,
      0,
      0,
      controller,
      visibleChildren,
      nodeSizes,
      subtreeWidths,
      positionedNodes,
      config,
    );

    final rawBounds = _computeBounds(positionedNodes.values);
    final shift = Offset(
      config.canvasPadding - rawBounds.left,
      config.canvasPadding - rawBounds.top,
    );
    final shiftedNodes = <int, EvalTreeLayoutNode>{
      for (final entry in positionedNodes.entries)
        entry.key: EvalTreeLayoutNode(
          nodeId: entry.value.nodeId,
          position: entry.value.position + shift,
          size: entry.value.size,
          isSelected: entry.value.isSelected,
        ),
    };
    final contentBounds = _computeBounds(shiftedNodes.values);
    final canvasSize = Size(
      contentBounds.right + config.canvasPadding,
      contentBounds.bottom + config.canvasPadding,
    );
    final edges = <EvalTreeLayoutEdge>[
      for (final entry in visibleChildren.entries)
        for (final childId in entry.value)
          EvalTreeLayoutEdge(
            sourceNodeId: entry.key,
            destinationNodeId: childId,
          ),
    ];

    return EvalTreeLayoutFrame(
      rootNodeId: rootNodeId,
      selectedNodeId: selectedNodeId,
      hitDisplayCap: visibleNodeIds.length >= controller.maxDisplayNodes &&
          snapshot.nodeCount > visibleNodeIds.length,
      canvasSize: canvasSize,
      contentBounds: contentBounds,
      nodesById: shiftedNodes,
      edges: edges,
    );
  }

  static Set<int> _buildVisibleNodeIds(
    EvalTreeSnapshot snapshot,
    EvalTreeController controller,
    int selectedNodeId,
  ) {
    final maxDisplayNodes = controller.maxDisplayNodes;
    if (maxDisplayNodes <= 0) {
      return {selectedNodeId};
    }

    final visibleNodeIds = <int>{};

    if (controller.showAncestorSpine) {
      final spine = snapshot.pathToRootIds(selectedNodeId);
      final startIndex = math.max(0, spine.length - maxDisplayNodes);
      for (final nodeId in spine.skip(startIndex)) {
        visibleNodeIds.add(nodeId);
      }
    } else {
      visibleNodeIds.add(selectedNodeId);
    }

    final descendantBudget =
        math.max(0, maxDisplayNodes - visibleNodeIds.length);
    _addDescendants(
      snapshot,
      selectedNodeId,
      controller.visiblePly,
      descendantBudget,
      visibleNodeIds,
    );
    return visibleNodeIds;
  }

  static int _resolveVisibleRootNodeId(
    EvalTreeSnapshot snapshot,
    int selectedNodeId,
    Set<int> visibleNodeIds,
  ) {
    for (final nodeId in snapshot.pathToRootIds(selectedNodeId)) {
      if (visibleNodeIds.contains(nodeId)) {
        return nodeId;
      }
    }
    return selectedNodeId;
  }

  static void _addDescendants(
    EvalTreeSnapshot snapshot,
    int nodeId,
    int remainingPly,
    int budget,
    Set<int> visibleNodeIds,
  ) {
    if (remainingPly <= 0 || budget <= 0) return;

    final node = snapshot.node(nodeId);
    if (node.childIds.isEmpty) return;

    var remainingBudget = budget;
    final visibleChildren = <int>[];
    for (final childId in node.childIds) {
      if (!visibleNodeIds.contains(childId)) {
        if (remainingBudget <= 0) break;
        visibleNodeIds.add(childId);
        remainingBudget--;
      }
      if (visibleNodeIds.contains(childId)) {
        visibleChildren.add(childId);
      }
    }

    if (remainingPly == 1 ||
        remainingBudget <= 0 ||
        visibleChildren.isEmpty) {
      return;
    }

    final childWeights = <int, int>{
      for (final childId in visibleChildren)
        childId: math.max(1, snapshot.node(childId).subtreeSize - 1),
    };
    final totalWeight =
        childWeights.values.fold<int>(0, (sum, value) => sum + value);
    final childBudgets = <int, int>{};
    var distributable = remainingBudget;
    for (final childId in visibleChildren) {
      if (distributable <= 0) {
        childBudgets[childId] = 0;
        continue;
      }
      final weight = childWeights[childId]!;
      final allocation = totalWeight == 0
          ? 0
          : (remainingBudget * weight / totalWeight).floor();
      childBudgets[childId] = allocation;
      distributable -= allocation;
    }

    var childIndex = 0;
    while (distributable > 0 && visibleChildren.isNotEmpty) {
      final childId = visibleChildren[childIndex % visibleChildren.length];
      childBudgets.update(childId, (value) => value + 1, ifAbsent: () => 1);
      distributable--;
      childIndex++;
    }

    for (final childId in visibleChildren) {
      _addDescendants(
        snapshot,
        childId,
        remainingPly - 1,
        childBudgets[childId] ?? 0,
        visibleNodeIds,
      );
    }
  }

  static double _measureSubtreeWidths(
    int nodeId,
    Map<int, List<int>> visibleChildren,
    Map<int, Size> nodeSizes,
    Map<int, double> subtreeWidths,
    EvalTreeLayoutConfig config,
  ) {
    final children = visibleChildren[nodeId] ?? const <int>[];
    final nodeWidth = nodeSizes[nodeId]!.width;
    if (children.isEmpty) {
      subtreeWidths[nodeId] = nodeWidth;
      return nodeWidth;
    }

    var childrenWidth = 0.0;
    for (var index = 0; index < children.length; index++) {
      final childId = children[index];
      childrenWidth += _measureSubtreeWidths(
        childId,
        visibleChildren,
        nodeSizes,
        subtreeWidths,
        config,
      );
      if (index < children.length - 1) {
        childrenWidth += config.horizontalGap;
      }
    }

    final width = math.max(nodeWidth, childrenWidth);
    subtreeWidths[nodeId] = width;
    return width;
  }

  static void _positionNode(
    int nodeId,
    double left,
    int ply,
    EvalTreeController controller,
    Map<int, List<int>> visibleChildren,
    Map<int, Size> nodeSizes,
    Map<int, double> subtreeWidths,
    Map<int, EvalTreeLayoutNode> positionedNodes,
    EvalTreeLayoutConfig config,
  ) {
    final nodeSize = nodeSizes[nodeId]!;
    final subtreeWidth = subtreeWidths[nodeId]!;
    final nodeLeft = left + (subtreeWidth - nodeSize.width) / 2;
    final position = Offset(nodeLeft, ply * config.verticalGap);
    positionedNodes[nodeId] = EvalTreeLayoutNode(
      nodeId: nodeId,
      position: position,
      size: nodeSize,
      isSelected: controller.selectedNodeId == nodeId,
    );

    final children = visibleChildren[nodeId] ?? const <int>[];
    if (children.isEmpty) return;

    var childrenWidth = 0.0;
    for (var index = 0; index < children.length; index++) {
      childrenWidth += subtreeWidths[children[index]]!;
      if (index < children.length - 1) {
        childrenWidth += config.horizontalGap;
      }
    }

    var childLeft = left + (subtreeWidth - childrenWidth) / 2;
    for (final childId in children) {
      _positionNode(
        childId,
        childLeft,
        ply + 1,
        controller,
        visibleChildren,
        nodeSizes,
        subtreeWidths,
        positionedNodes,
        config,
      );
      childLeft += subtreeWidths[childId]! + config.horizontalGap;
    }
  }

  static Size _estimateNodeSize(
    EvalTreeSnapshot snapshot,
    EvalTreeNodeSnapshot node,
    EvalTreeMetricDisplayMode metricDisplayMode,
    EvalTreeLayoutConfig config,
  ) {
    final secondaryLabel = _secondaryLabelForNode(
      snapshot,
      node,
      metricDisplayMode,
    );
    final titleWidth = _measureSingleLineWidth(
      node.displayLabel,
      _nodeTitleMeasureStyle,
    );
    final secondaryWidth = secondaryLabel == null
        ? 0.0
        : _measureSingleLineWidth(secondaryLabel, _nodeSecondaryMeasureStyle);
    final rawWidth = math.max(titleWidth, secondaryWidth) +
        (nodeHorizontalPadding * 2) +
        _nodeTextWidthBuffer;
    final width = rawWidth > config.maxNodeWidth
        ? rawWidth
        : rawWidth.clamp(config.minNodeWidth, config.maxNodeWidth).toDouble();
    return Size(
      width,
      secondaryLabel != null
          ? config.expandedNodeHeight
          : config.compactNodeHeight,
    );
  }

  static double _measureSingleLineWidth(String text, TextStyle style) {
    if (text.isEmpty) return 0;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter.width.ceilToDouble();
  }

  static Rect _computeBounds(Iterable<EvalTreeLayoutNode> nodes) {
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;

    for (final node in nodes) {
      final rect = node.rect;
      left = math.min(left, rect.left);
      top = math.min(top, rect.top);
      right = math.max(right, rect.right);
      bottom = math.max(bottom, rect.bottom);
    }

    if (!left.isFinite) {
      return Rect.zero;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  static String? subtitleForNode(
    EvalTreeSnapshot snapshot,
    EvalTreeNodeSnapshot node,
    EvalTreeMetricDisplayMode metricDisplayMode,
  ) {
    return _subtitleForNode(snapshot, node, metricDisplayMode);
  }

  static String? secondaryLabelForNode(
    EvalTreeSnapshot snapshot,
    EvalTreeNodeSnapshot node,
    EvalTreeMetricDisplayMode metricDisplayMode,
  ) {
    return _secondaryLabelForNode(snapshot, node, metricDisplayMode);
  }

  static String? _secondaryLabelForNode(
    EvalTreeSnapshot snapshot,
    EvalTreeNodeSnapshot node,
    EvalTreeMetricDisplayMode metricDisplayMode,
  ) {
    final metricLabel = _subtitleForNode(snapshot, node, metricDisplayMode);
    final probabilityLabel = _probabilityLabelForNode(snapshot, node);
    if (probabilityLabel == null) {
      return metricLabel;
    }
    if (metricLabel == null) {
      return probabilityLabel;
    }
    return '$probabilityLabel $metricLabel';
  }

  static String? _subtitleForNode(
    EvalTreeSnapshot snapshot,
    EvalTreeNodeSnapshot node,
    EvalTreeMetricDisplayMode metricDisplayMode,
  ) {
    if (metricDisplayMode == EvalTreeMetricDisplayMode.cpl &&
        _isOurMoveNode(snapshot, node)) {
      final localCpl = node.localCpl;
      if (localCpl != null) {
        return '${localCpl.toStringAsFixed(0)}cpl';
      }
    }

    final evalForUsCp = node.evalForUsCp;
    if (evalForUsCp == null) return null;
    if (evalForUsCp.abs() >= 10000) {
      return evalForUsCp > 0 ? '+M' : '-M';
    }
    final pawns = evalForUsCp / 100.0;
    return '${pawns >= 0 ? "+" : ""}${pawns.toStringAsFixed(1)}';
  }

  static String? _probabilityLabelForNode(
    EvalTreeSnapshot snapshot,
    EvalTreeNodeSnapshot node,
  ) {
    final parent = snapshot.parentOf(node.id);
    if (parent == null) {
      return null;
    }

    final isOpponentMove = parent.sideToMoveIsWhite != snapshot.playAsWhite;
    if (!isOpponentMove) {
      return null;
    }

    final percentage = node.moveProbability * 100;
    if (percentage > 0 && percentage < 1) {
      return '<1%';
    }
    return '${percentage.toStringAsFixed(0)}%';
  }

  static bool _isOurMoveNode(
    EvalTreeSnapshot snapshot,
    EvalTreeNodeSnapshot node,
  ) {
    final parent = snapshot.parentOf(node.id);
    if (parent == null) {
      return false;
    }
    return parent.sideToMoveIsWhite == snapshot.playAsWhite;
  }
}
