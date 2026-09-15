/// View state of the eval-tree viewer: which snapshot is loaded, which node
/// is selected, how much of the tree around it is shown, and pending "bring
/// this node into view" requests the viewport consumes.
library;

import 'package:flutter/material.dart';

import '../../../utils/safe_change_notifier.dart';
import '../models/eval_tree_snapshot.dart';

enum EvalTreeMetricDisplayMode { cpl, eval }

class EvalTreeController extends ChangeNotifier with SafeChangeNotifier {
  /// How many plies below the selection may be shown.
  static const int minVisiblePly = 1;
  static const int maxVisiblePly = 8;

  /// Bounds on the focused window's node budget (see the tree display
  /// architecture doc: never lay out the whole tree).
  static const int minDisplayNodes = 1;
  static const int maxDisplayNodesCap = 1000;
  static const int defaultMaxDisplayNodes = 400;

  EvalTreeSnapshot? _snapshot;
  int? _selectedNodeId;
  int _visiblePly = minVisiblePly;
  bool _showAncestorSpine = true;
  int _maxDisplayNodes = defaultMaxDisplayNodes;
  EvalTreeMetricDisplayMode _metricDisplayMode = EvalTreeMetricDisplayMode.cpl;
  int _focusRequestId = 0;
  int? _focusTargetNodeId;
  bool _focusResetZoom = false;

  final TransformationController transformationController =
      TransformationController();

  EvalTreeSnapshot? get snapshot => _snapshot;
  bool get hasSnapshot => _snapshot != null;

  int get visiblePly => _visiblePly;
  bool get showAncestorSpine => _showAncestorSpine;
  int get maxDisplayNodes => _maxDisplayNodes;
  EvalTreeMetricDisplayMode get metricDisplayMode => _metricDisplayMode;

  /// Bumped on every focus request so the viewport can tell a new request
  /// from the one it already handled.
  int get focusRequestId => _focusRequestId;
  int? get focusTargetNodeId => _focusTargetNodeId;
  bool get focusResetZoom => _focusResetZoom;

  /// The selected node, or the root when nothing was selected; null without
  /// a snapshot.
  int? get selectedNodeId {
    final snapshot = _snapshot;
    if (snapshot == null) return null;
    return _selectedNodeId ?? snapshot.rootNodeId;
  }

  EvalTreeNodeSnapshot? get selectedNode {
    final snapshot = _snapshot;
    final nodeId = selectedNodeId;
    if (snapshot == null || nodeId == null) return null;
    return snapshot.tryNode(nodeId);
  }

  void loadSnapshot(
    EvalTreeSnapshot snapshot, {
    int? selectedNodeId,
    bool resetView = true,
  }) {
    _snapshot = snapshot;
    _selectedNodeId =
        selectedNodeId != null && snapshot.containsNode(selectedNodeId)
        ? selectedNodeId
        : snapshot.rootNodeId;
    if (resetView) {
      transformationController.value = Matrix4.identity();
      _requestFocus(_selectedNodeId, resetZoom: true);
    }
    notifyListeners();
  }

  void clearSnapshot() {
    _snapshot = null;
    _selectedNodeId = null;
    _visiblePly = minVisiblePly;
    _showAncestorSpine = true;
    _metricDisplayMode = EvalTreeMetricDisplayMode.cpl;
    _focusTargetNodeId = null;
    _focusResetZoom = false;
    transformationController.value = Matrix4.identity();
    notifyListeners();
  }

  /// Selects [nodeId]; returns false when it is unknown or already selected
  /// without a focus request to renew.
  bool selectNode(int nodeId, {bool requestFocus = true}) {
    final snapshot = _snapshot;
    if (snapshot == null || !snapshot.containsNode(nodeId)) return false;
    if (_selectedNodeId == nodeId && !requestFocus) return false;
    _selectedNodeId = nodeId;
    if (requestFocus) _requestFocus(nodeId);
    notifyListeners();
    return true;
  }

  bool goParent() {
    final parentId = selectedNode?.parentId;
    return parentId != null && selectNode(parentId);
  }

  bool goPreferredChild() {
    final snapshot = _snapshot;
    final nodeId = selectedNodeId;
    if (snapshot == null || nodeId == null) return false;
    final preferredChildId = snapshot.preferredChildId(nodeId);
    return preferredChildId != null && selectNode(preferredChildId);
  }

  bool goRoot() {
    final snapshot = _snapshot;
    return snapshot != null && selectNode(snapshot.rootNodeId);
  }

  void requestFocusSelection({bool resetZoom = false}) {
    _requestFocus(selectedNodeId, resetZoom: resetZoom);
    notifyListeners();
  }

  void requestFocusRoot({bool resetZoom = true}) {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    _requestFocus(snapshot.rootNodeId, resetZoom: resetZoom);
    notifyListeners();
  }

  void clearFocusRequest() {
    _focusTargetNodeId = null;
    _focusResetZoom = false;
  }

  void setVisiblePly(int ply) {
    final clamped = ply.clamp(minVisiblePly, maxVisiblePly);
    if (_visiblePly == clamped) return;
    _visiblePly = clamped;
    _requestFocus(selectedNodeId);
    notifyListeners();
  }

  void toggleAncestorSpine() => setAncestorSpine(!_showAncestorSpine);

  void setAncestorSpine(bool value) {
    if (_showAncestorSpine == value) return;
    _showAncestorSpine = value;
    _requestFocus(selectedNodeId);
    notifyListeners();
  }

  void setMaxDisplayNodes(int value) {
    final clamped = value.clamp(minDisplayNodes, maxDisplayNodesCap);
    if (_maxDisplayNodes == clamped) return;
    _maxDisplayNodes = clamped;
    _requestFocus(selectedNodeId);
    notifyListeners();
  }

  void setMetricDisplayMode(EvalTreeMetricDisplayMode value) {
    if (_metricDisplayMode == value) return;
    _metricDisplayMode = value;
    notifyListeners();
  }

  void _requestFocus(int? nodeId, {bool resetZoom = false}) {
    if (nodeId == null) return;
    _focusTargetNodeId = nodeId;
    _focusResetZoom = resetZoom;
    _focusRequestId++;
  }

  @override
  void dispose() {
    transformationController.dispose();
    super.dispose();
  }
}
