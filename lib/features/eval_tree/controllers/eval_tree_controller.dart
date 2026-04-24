import 'package:flutter/material.dart';

import '../models/eval_tree_snapshot.dart';

enum EvalTreeMetricDisplayMode {
  cpl,
  eval,
}

class EvalTreeController extends ChangeNotifier {
  EvalTreeSnapshot? _snapshot;
  int? _selectedNodeId;
  int _visiblePly = 1;
  bool _showAncestorSpine = true;
  int _maxDisplayNodes = 400;
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
  int get focusRequestId => _focusRequestId;
  int? get focusTargetNodeId => _focusTargetNodeId;
  bool get focusResetZoom => _focusResetZoom;

  int? get selectedNodeId {
    if (_snapshot == null) return null;
    return _selectedNodeId ?? _snapshot!.rootNodeId;
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
    _visiblePly = 1;
    _showAncestorSpine = true;
    _metricDisplayMode = EvalTreeMetricDisplayMode.cpl;
    _focusTargetNodeId = null;
    _focusResetZoom = false;
    transformationController.value = Matrix4.identity();
    notifyListeners();
  }

  bool selectNode(int nodeId, {bool requestFocus = true}) {
    final snapshot = _snapshot;
    if (snapshot == null || !snapshot.containsNode(nodeId)) return false;
    if (_selectedNodeId == nodeId && !requestFocus) return false;
    _selectedNodeId = nodeId;
    if (requestFocus) {
      _requestFocus(nodeId);
    }
    notifyListeners();
    return true;
  }

  bool goParent() {
    final snapshot = _snapshot;
    final current = selectedNode;
    if (snapshot == null || current?.parentId == null) return false;
    return selectNode(current!.parentId!);
  }

  bool goPreferredChild() {
    final snapshot = _snapshot;
    final nodeId = selectedNodeId;
    if (snapshot == null || nodeId == null) return false;
    final preferredChildId = snapshot.preferredChildId(nodeId);
    if (preferredChildId == null) return false;
    return selectNode(preferredChildId);
  }

  bool goRoot() {
    final snapshot = _snapshot;
    if (snapshot == null) return false;
    return selectNode(snapshot.rootNodeId);
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
    final clamped = ply.clamp(1, 8);
    if (_visiblePly == clamped) return;
    _visiblePly = clamped;
    _requestFocus(selectedNodeId);
    notifyListeners();
  }

  void toggleAncestorSpine() {
    _showAncestorSpine = !_showAncestorSpine;
    _requestFocus(selectedNodeId);
    notifyListeners();
  }

  void setAncestorSpine(bool value) {
    if (_showAncestorSpine == value) return;
    _showAncestorSpine = value;
    _requestFocus(selectedNodeId);
    notifyListeners();
  }

  void setMaxDisplayNodes(int value) {
    final clamped = value.clamp(1, 1000);
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
