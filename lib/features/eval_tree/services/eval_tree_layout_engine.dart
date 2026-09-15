/// Lays out the focused window of an eval tree — the ancestor spine, the
/// selected node and a budgeted set of its descendants — as a top-down tree
/// of measured chips.
///
/// See `docs/tree-display-architecture.md`: the whole tree is never laid out;
/// [EvalTreeController.maxDisplayNodes] caps the window, and the budget left
/// after the spine is shared among the selection's children in proportion to
/// their subtree sizes.
library;

import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../utils/chess_utils.dart' show formatPackedEval;
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

  EvalTreeLayoutNode shiftedBy(Offset offset) => EvalTreeLayoutNode(
    nodeId: nodeId,
    position: position + offset,
    size: size,
    isSelected: isSelected,
  );
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

  /// Nodes in paint order (top to bottom, left to right). Sorted once per
  /// frame; the viewport reads this on every rebuild.
  late final List<EvalTreeLayoutNode> nodes = nodesById.values.toList()
    ..sort((a, b) {
      final vertical = a.position.dy.compareTo(b.position.dy);
      if (vertical != 0) return vertical;
      return a.position.dx.compareTo(b.position.dx);
    });

  EvalTreeLayoutNode? tryNode(int nodeId) => nodesById[nodeId];
}

/// Measured node sizes for one snapshot and metric mode.
///
/// A node's size depends only on its labels, which the snapshot fixes, and
/// on the metric shown; the layout engine used to lay out two `TextPainter`s
/// per visible node on every select and zoom. Hand the same cache to every
/// `buildFrame` call for a snapshot and each node is measured once per mode.
class EvalTreeNodeSizeCache {
  EvalTreeNodeSizeCache(this.snapshot);

  final EvalTreeSnapshot snapshot;
  final Map<EvalTreeMetricDisplayMode, Map<int, Size>> _byMode = {};

  Size sizeOf(
    int nodeId,
    EvalTreeMetricDisplayMode mode,
    Size Function() measure,
  ) => (_byMode[mode] ??= {}).putIfAbsent(nodeId, measure);
}

class EvalTreeLayoutEngine {
  static const double nodeHorizontalPadding = 8;
  static const double nodeVerticalPadding = 5;
  static const double nodeTitleFontSize = 13;
  static const double nodeSecondaryFontSize = 11;
  static const String nodeFontFamily = 'SourceCodePro';
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

  /// Lay out the visible part of [snapshot] for [controller]'s view state.
  ///
  /// [sizeCache] must belong to [snapshot]; pass one to reuse node
  /// measurements across frames.
  static EvalTreeLayoutFrame buildFrame(
    EvalTreeSnapshot snapshot,
    EvalTreeController controller, {
    EvalTreeLayoutConfig config = const EvalTreeLayoutConfig(),
    EvalTreeNodeSizeCache? sizeCache,
  }) {
    assert(sizeCache == null || identical(sizeCache.snapshot, snapshot));
    return _FrameLayout(
      snapshot: snapshot,
      selectedNodeId: controller.selectedNodeId ?? snapshot.rootNodeId,
      showAncestorSpine: controller.showAncestorSpine,
      visiblePly: controller.visiblePly,
      maxDisplayNodes: controller.maxDisplayNodes,
      mode: controller.metricDisplayMode,
      config: config,
      sizeCache: sizeCache,
    ).build();
  }

  /// The size a chip needs for its labels: at least [config]'s minimum, at
  /// most its maximum unless the text itself is wider.
  static Size measureNode(
    EvalTreeSnapshot snapshot,
    EvalTreeNodeSnapshot node,
    EvalTreeMetricDisplayMode metricDisplayMode,
    EvalTreeLayoutConfig config,
  ) {
    final secondaryLabel = secondaryLabelForNode(
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
    final rawWidth =
        math.max(titleWidth, secondaryWidth) +
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

  /// The metric under a chip: our move's loss in cpl mode when known, else
  /// the evaluation for us; null without either.
  static String? subtitleForNode(
    EvalTreeSnapshot snapshot,
    EvalTreeNodeSnapshot node,
    EvalTreeMetricDisplayMode metricDisplayMode,
  ) {
    if (metricDisplayMode == EvalTreeMetricDisplayMode.cpl &&
        snapshot.isOurMove(node.id)) {
      final localCpl = node.localCpl;
      if (localCpl != null) return '${localCpl.toStringAsFixed(0)}cpl';
    }
    final evalForUsCp = node.evalForUsCp;
    return evalForUsCp == null ? null : formatPackedEval(evalForUsCp);
  }

  /// The whole second line of a chip: the opponent reply's probability, the
  /// metric, or both ("58% +0.1").
  static String? secondaryLabelForNode(
    EvalTreeSnapshot snapshot,
    EvalTreeNodeSnapshot node,
    EvalTreeMetricDisplayMode metricDisplayMode,
  ) {
    final metricLabel = subtitleForNode(snapshot, node, metricDisplayMode);
    final probabilityLabel = _probabilityLabelForNode(snapshot, node);
    if (probabilityLabel == null) return metricLabel;
    if (metricLabel == null) return probabilityLabel;
    return '$probabilityLabel $metricLabel';
  }

  /// How likely the opponent is to play this reply; null for our own moves
  /// and the root.
  static String? _probabilityLabelForNode(
    EvalTreeSnapshot snapshot,
    EvalTreeNodeSnapshot node,
  ) {
    if (snapshot.parentOf(node.id) == null || snapshot.isOurMove(node.id)) {
      return null;
    }
    final percentage = node.moveProbability * 100;
    if (percentage > 0 && percentage < 1) return '<1%';
    return '${percentage.toStringAsFixed(0)}%';
  }
}

/// One frame's layout: picks the visible window, measures its nodes, then
/// positions each subtree centred over its children.
class _FrameLayout {
  _FrameLayout({
    required this.snapshot,
    required this.selectedNodeId,
    required this.showAncestorSpine,
    required this.visiblePly,
    required this.maxDisplayNodes,
    required this.mode,
    required this.config,
    required this.sizeCache,
  });

  final EvalTreeSnapshot snapshot;
  final int selectedNodeId;
  final bool showAncestorSpine;
  final int visiblePly;
  final int maxDisplayNodes;
  final EvalTreeMetricDisplayMode mode;
  final EvalTreeLayoutConfig config;
  final EvalTreeNodeSizeCache? sizeCache;

  /// Visible children of each visible node, in the snapshot's order.
  final Map<int, List<int>> _visibleChildren = {};
  final Map<int, Size> _nodeSizes = {};
  final Map<int, double> _subtreeWidths = {};
  final Map<int, EvalTreeLayoutNode> _positioned = {};

  EvalTreeLayoutFrame build() {
    final visibleNodeIds = _visibleNodeIds();
    final rootNodeId = showAncestorSpine
        ? _visibleRootNodeId(visibleNodeIds)
        : selectedNodeId;
    for (final nodeId in visibleNodeIds) {
      _visibleChildren[nodeId] = [
        for (final childId in snapshot.node(nodeId).childIds)
          if (visibleNodeIds.contains(childId)) childId,
      ];
      _nodeSizes[nodeId] = _sizeOf(nodeId);
    }
    _measureSubtreeWidth(rootNodeId);
    _positionNode(rootNodeId, 0, 0);

    final rawBounds = _computeBounds(_positioned.values);
    final shift = Offset(
      config.canvasPadding - rawBounds.left,
      config.canvasPadding - rawBounds.top,
    );
    final shiftedNodes = {
      for (final entry in _positioned.entries)
        entry.key: entry.value.shiftedBy(shift),
    };
    final contentBounds = _computeBounds(shiftedNodes.values);
    return EvalTreeLayoutFrame(
      rootNodeId: rootNodeId,
      selectedNodeId: selectedNodeId,
      hitDisplayCap:
          visibleNodeIds.length >= maxDisplayNodes &&
          snapshot.nodeCount > visibleNodeIds.length,
      canvasSize: Size(
        contentBounds.right + config.canvasPadding,
        contentBounds.bottom + config.canvasPadding,
      ),
      contentBounds: contentBounds,
      nodesById: shiftedNodes,
      edges: [
        for (final entry in _visibleChildren.entries)
          for (final childId in entry.value)
            EvalTreeLayoutEdge(
              sourceNodeId: entry.key,
              destinationNodeId: childId,
            ),
      ],
    );
  }

  Size _sizeOf(int nodeId) {
    Size measure() => EvalTreeLayoutEngine.measureNode(
      snapshot,
      snapshot.node(nodeId),
      mode,
      config,
    );
    final cache = sizeCache;
    return cache == null ? measure() : cache.sizeOf(nodeId, mode, measure);
  }

  // ── Which nodes are shown ────────────────────────────────────────────────

  /// The spine above the selection (its last [maxDisplayNodes] nodes when it
  /// is longer), then descendants of the selection with what is left.
  Set<int> _visibleNodeIds() {
    if (maxDisplayNodes <= 0) return {selectedNodeId};
    final visibleNodeIds = <int>{};
    if (showAncestorSpine) {
      final spine = snapshot.pathToRootIds(selectedNodeId);
      final startIndex = math.max(0, spine.length - maxDisplayNodes);
      visibleNodeIds.addAll(spine.skip(startIndex));
    } else {
      visibleNodeIds.add(selectedNodeId);
    }
    final descendantBudget = math.max(
      0,
      maxDisplayNodes - visibleNodeIds.length,
    );
    _addDescendants(
      selectedNodeId,
      visiblePly,
      descendantBudget,
      visibleNodeIds,
    );
    return visibleNodeIds;
  }

  /// The topmost spine node that made it into the window.
  int _visibleRootNodeId(Set<int> visibleNodeIds) {
    for (final nodeId in snapshot.pathToRootIds(selectedNodeId)) {
      if (visibleNodeIds.contains(nodeId)) return nodeId;
    }
    return selectedNodeId;
  }

  /// Adds children of [nodeId] while [budget] lasts, then shares the rest of
  /// the budget among the added children in proportion to their subtree
  /// sizes (any remainder round-robin) and recurses [remainingPly] deep.
  void _addDescendants(
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
      if (visibleNodeIds.contains(childId)) visibleChildren.add(childId);
    }
    if (remainingPly == 1 || remainingBudget <= 0 || visibleChildren.isEmpty) {
      return;
    }

    final childBudgets = _shareBudget(remainingBudget, visibleChildren);
    for (final childId in visibleChildren) {
      _addDescendants(
        childId,
        remainingPly - 1,
        childBudgets[childId] ?? 0,
        visibleNodeIds,
      );
    }
  }

  Map<int, int> _shareBudget(int budget, List<int> children) {
    final childWeights = {
      for (final childId in children)
        childId: math.max(1, snapshot.node(childId).subtreeSize - 1),
    };
    final totalWeight = childWeights.values.fold<int>(0, (a, b) => a + b);
    final childBudgets = <int, int>{};
    var distributable = budget;
    for (final childId in children) {
      if (distributable <= 0) {
        childBudgets[childId] = 0;
        continue;
      }
      final allocation = totalWeight == 0
          ? 0
          : (budget * childWeights[childId]! / totalWeight).floor();
      childBudgets[childId] = allocation;
      distributable -= allocation;
    }
    var childIndex = 0;
    while (distributable > 0 && children.isNotEmpty) {
      final childId = children[childIndex % children.length];
      childBudgets.update(childId, (value) => value + 1, ifAbsent: () => 1);
      distributable--;
      childIndex++;
    }
    return childBudgets;
  }

  // ── Placing them ─────────────────────────────────────────────────────────

  double _measureSubtreeWidth(int nodeId) {
    final children = _visibleChildren[nodeId] ?? const <int>[];
    final nodeWidth = _nodeSizes[nodeId]!.width;
    final width = children.isEmpty
        ? nodeWidth
        : math.max(nodeWidth, _childrenWidth(children, _measureSubtreeWidth));
    _subtreeWidths[nodeId] = width;
    return width;
  }

  /// Subtree widths of [children] laid side by side with the horizontal gap.
  double _childrenWidth(List<int> children, double Function(int) widthOf) {
    var width = 0.0;
    for (final (index, childId) in children.indexed) {
      width += widthOf(childId);
      if (index < children.length - 1) width += config.horizontalGap;
    }
    return width;
  }

  /// Centres [nodeId] over its subtree, which starts at [left], and lays its
  /// children out one row down, centred as a block under it.
  void _positionNode(int nodeId, double left, int ply) {
    final nodeSize = _nodeSizes[nodeId]!;
    final subtreeWidth = _subtreeWidths[nodeId]!;
    _positioned[nodeId] = EvalTreeLayoutNode(
      nodeId: nodeId,
      position: Offset(
        left + (subtreeWidth - nodeSize.width) / 2,
        ply * config.verticalGap,
      ),
      size: nodeSize,
      isSelected: selectedNodeId == nodeId,
    );

    final children = _visibleChildren[nodeId] ?? const <int>[];
    if (children.isEmpty) return;
    final childrenWidth = _childrenWidth(children, (id) => _subtreeWidths[id]!);
    var childLeft = left + (subtreeWidth - childrenWidth) / 2;
    for (final childId in children) {
      _positionNode(childId, childLeft, ply + 1);
      childLeft += _subtreeWidths[childId]! + config.horizontalGap;
    }
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
    if (!left.isFinite) return Rect.zero;
    return Rect.fromLTRB(left, top, right, bottom);
  }
}
