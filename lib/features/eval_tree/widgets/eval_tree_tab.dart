import 'dart:async';

import '../../../utils/isolate_task.dart';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../constants/chess_constants.dart';
import '../../../models/build_tree_node.dart';
import '../../../models/repertoire_metadata.dart';
import '../services/eval_tree_file_loader.dart';
import '../../../services/generation/tree_serialization.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../tree_colors.dart';
import '../adapters/eval_tree_snapshot_adapter.dart';
import '../controllers/eval_tree_controller.dart';
import '../models/eval_tree_snapshot.dart';
import '../services/eval_tree_layout_engine.dart';
import '../services/eval_tree_line_metrics.dart';
import 'eval_tree_toolbar.dart';
import 'eval_tree_viewport.dart';
import '../../../widgets/layout/empty_state_placeholder.dart';
import 'repertoire_tree_explorer.dart';

class EvalTreePositionSelection {
  final String fen;
  final String rootFen;
  final List<String> movePathSan;
  final List<String> rootStartMovesSan;

  EvalTreePositionSelection({
    required this.fen,
    required this.rootFen,
    required List<String> movePathSan,
    required List<String> rootStartMovesSan,
  }) : movePathSan = List.unmodifiable(movePathSan),
       rootStartMovesSan = List.unmodifiable(rootStartMovesSan);

  List<String> get fullMovePathSan => [...rootStartMovesSan, ...movePathSan];

  String? get startingFen {
    if (rootStartMovesSan.isNotEmpty || rootFen == kStandardStartFen) {
      return null;
    }
    return rootFen;
  }
}

class EvalTreeTab extends StatefulWidget {
  final RepertoireMetadata? currentRepertoire;
  final bool isWhiteRepertoire;
  final BuildTree? generatedTree;
  final int treeResetCounter;
  final ValueChanged<EvalTreePositionSelection>? onPositionSelected;
  final ValueChanged<EvalTreeController?>? onControllerReady;

  const EvalTreeTab({
    super.key,
    required this.currentRepertoire,
    required this.isWhiteRepertoire,
    required this.generatedTree,
    required this.treeResetCounter,
    this.onPositionSelected,
    this.onControllerReady,
  });

  @override
  State<EvalTreeTab> createState() => _EvalTreeTabState();
}

class _EvalTreeTabState extends State<EvalTreeTab>
    with AutomaticKeepAliveClientMixin {
  final EvalTreeController _controller = EvalTreeController();

  int? _maxPly;
  IsolateTask? _loadTask;
  EvalTreeSnapshot? _snapshot;
  EvalTreeLineMetricsCache? _metricsCache;

  /// Node measurements for [_snapshot]; replaced with it.
  EvalTreeNodeSizeCache? _sizeCache;

  /// The last frame and the view state it was built for.  A controller
  /// notification that changes none of the frame's inputs (a focus request,
  /// say) reuses it instead of laying the tree out again.
  _FrameMemo? _frameMemo;

  EvalTreeLayoutFrame _frameFor(EvalTreeSnapshot snapshot) {
    final key = _FrameKey(
      snapshot: snapshot,
      selectedNodeId: _controller.selectedNodeId,
      visiblePly: _controller.visiblePly,
      showAncestorSpine: _controller.showAncestorSpine,
      maxDisplayNodes: _controller.maxDisplayNodes,
      metricDisplayMode: _controller.metricDisplayMode,
    );
    final memo = _frameMemo;
    if (memo != null && memo.key == key) return memo.frame;
    var sizes = _sizeCache;
    if (sizes == null || !identical(sizes.snapshot, snapshot)) {
      sizes = _sizeCache = EvalTreeNodeSizeCache(snapshot);
    }
    final frame = EvalTreeLayoutEngine.buildFrame(
      snapshot,
      _controller,
      sizeCache: sizes,
    );
    _frameMemo = _FrameMemo(key, frame);
    return frame;
  }

  bool _isLoading = false;
  String? _error;
  bool _dismissed = false;
  int? _lastNotifiedNodeId;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleControllerChanged);
    widget.onControllerReady?.call(_controller);
    _restoreInitialTree();
  }

  @override
  void didUpdateWidget(covariant EvalTreeTab oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.onControllerReady != widget.onControllerReady) {
      widget.onControllerReady?.call(_controller);
    }

    final oldPath = oldWidget.currentRepertoire?.filePath;
    final newPath = widget.currentRepertoire?.filePath;
    if (oldPath != newPath) {
      _dismissed = false;
      _clearTreeState();
      _restoreInitialTree();
      return;
    }

    if (oldWidget.treeResetCounter != widget.treeResetCounter) {
      _dismissed = false;
      _clearTreeState();
      return;
    }

    if (!identical(oldWidget.generatedTree, widget.generatedTree) &&
        widget.generatedTree != null) {
      _dismissed = false;
      unawaited(_setTree(widget.generatedTree!, resetView: true));
    }
  }

  @override
  void dispose() {
    _loadTask?.cancel();
    widget.onControllerReady?.call(null);
    _controller.removeListener(_handleControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              'Loading eval tree...',
              style: TextStyle(color: AppColors.onSurfaceMuted, fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (_snapshot == null) {
      return _buildEmptyState(context);
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final snapshot = _snapshot;
        final currentNode = _controller.selectedNode;
        if (snapshot == null || currentNode == null) {
          return _buildEmptyState(context);
        }

        final layoutFrame = _frameFor(snapshot);
        return Column(
          children: [
            _buildSummaryBar(context, snapshot),
            const Divider(height: 1),
            EvalTreeToolbar(
              controller: _controller,
              currentNode: currentNode,
              visibleNodeCount: layoutFrame.nodesById.length,
              totalNodeCount: snapshot.nodeCount,
              hitDisplayCap: layoutFrame.hitDisplayCap,
            ),
            _buildLegend(),
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    flex: 3,
                    child: RepertoireTreeExplorer(
                      snapshot: snapshot,
                      controller: _controller,
                      metricsCache:
                          _metricsCache ??
                          EvalTreeLineMetricsCache.fromSnapshot(snapshot),
                      currentNode: currentNode,
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    flex: 2,
                    child: EvalTreeViewport(
                      snapshot: snapshot,
                      controller: _controller,
                      frame: layoutFrame,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final hasPath = _treePath() != null;
    final message =
        _error ??
        (hasPath
            ? 'Generate a repertoire tree or load a saved tree file.'
            : 'Select a repertoire first.');

    return EmptyStatePlaceholder(
      icon: Icons.insights,
      title: 'No eval tree found',
      subtitle: message,
      actionLabel: hasPath ? 'Load from file' : null,
      actionIcon: Icons.file_open,
      onAction: hasPath ? _reloadFromFile : null,
    );
  }

  Widget _buildSummaryBar(BuildContext context, EvalTreeSnapshot snapshot) {
    final maxPly = _maxPly ?? snapshot.root.subtreePly;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Icon(Icons.insights, size: 16, color: AppColors.onSurfaceSoft),
          Text(
            '${snapshot.nodeCount} nodes • max ply $maxPly',
            style: AppTextStyles.caption,
          ),
          SizedBox(
            height: 28,
            child: TextButton.icon(
              onPressed: _reloadFromFile,
              icon: const Icon(
                Icons.refresh,
                size: 14,
                color: AppColors.onSurfaceSoft,
              ),
              label: const Text('Reload', style: AppTextStyles.caption),
            ),
          ),
          SizedBox(
            height: 28,
            child: TextButton.icon(
              onPressed: () {
                setState(() {
                  _dismissed = true;
                });
                _clearTreeState();
              },
              icon: const Icon(
                Icons.close,
                size: 14,
                color: AppColors.onSurfaceSoft,
              ),
              label: const Text('Close', style: AppTextStyles.caption),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegend() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          _legendDot(kNodeColorOurMove, 'Our best'),
          _legendDot(kNodeColorOpponentMove, 'Opponent best'),
          _legendDot(kNodeColorInaccuracy, 'Inaccuracy'),
          _legendDot(kNodeColorMistake, 'Mistake'),
          _legendDot(kNodeColorBlunder, 'Blunder'),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 3),
        // Deliberate 9→10px bump: 9px was below any legible floor on desktop
        // (flagged in the theme audit as a readability fix, not a drift).
        Text(label, style: AppTextStyles.caption.copyWith(fontSize: 12)),
      ],
    );
  }

  void _restoreInitialTree() {
    if (widget.generatedTree != null) {
      unawaited(_setTree(widget.generatedTree!, resetView: true));
      return;
    }
    if (_dismissed) return;
    unawaited(_reloadFromFile(autoLoad: true));
  }

  Future<void> _reloadFromFile({bool autoLoad = false}) async {
    final path = _treePath();
    if (path == null || path.isEmpty) return;
    _loadTask?.cancel();
    final task = _loadTask = IsolateTask();
    final playAsWhite = widget.isWhiteRepertoire;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      if (!isEvalTreeFileAccessSupported) {
        throw UnsupportedError(evalTreeFileAccessUnsupportedReason);
      }
      if (!await evalTreeFileExists(path)) {
        if (!mounted || task.isCancelled) return;
        setState(() {
          _isLoading = false;
          _error = autoLoad
              ? 'No saved tree file found for this repertoire yet.'
              : 'No tree file found. Generate a tree first.';
        });
        return;
      }
      final json = await readEvalTreeFile(path);
      if (!mounted || task.isCancelled) return;
      final prepared = await task.compute(_prepareSavedTree, (
        json,
        playAsWhite,
      ));
      if (!mounted || task.isCancelled) return;
      _installTree(prepared, resetView: true);
    } catch (error) {
      if (!mounted || task.isCancelled) return;
      setState(() {
        _isLoading = false;
        _error = 'Failed to load tree: $error';
      });
    }
  }

  Future<void> _setTree(BuildTree tree, {required bool resetView}) async {
    _loadTask?.cancel();
    final task = _loadTask = IsolateTask();
    final playAsWhite = widget.isWhiteRepertoire;
    setState(() => _isLoading = true);
    try {
      // Small generated trees fit within a frame. Large trees prepare all
      // derived data in one isolate and return only what this view uses.
      final prepared = tree.totalNodes <= 1000
          ? _prepareTree(tree, playAsWhite)
          : await task.compute(_prepareGeneratedTree, (tree, playAsWhite));
      if (!mounted || task.isCancelled) return;
      _installTree(prepared, resetView: resetView);
    } catch (error) {
      if (!mounted || task.isCancelled) return;
      setState(() {
        _isLoading = false;
        _error = 'Failed to prepare tree: $error';
        debugPrint(_error);
      });
    }
  }

  void _installTree(_PreparedTree prepared, {required bool resetView}) {
    setState(() {
      _maxPly = prepared.maxPly;
      _snapshot = prepared.snapshot;
      _metricsCache = prepared.metrics;
      _sizeCache = null;
      _frameMemo = null;
      _lastNotifiedNodeId = null;
      _isLoading = false;
      _error = null;
    });
    _controller.loadSnapshot(prepared.snapshot, resetView: resetView);
  }

  void _clearTreeState() {
    _loadTask?.cancel();
    setState(() {
      _maxPly = null;
      _sizeCache = null;
      _frameMemo = null;
      _snapshot = null;
      _metricsCache = null;
      _isLoading = false;
      _error = null;
    });
    _controller.clearSnapshot();
    _lastNotifiedNodeId = null;
  }

  void _handleControllerChanged() {
    final snapshot = _snapshot;
    final selected = _controller.selectedNode;
    if (snapshot == null ||
        selected == null ||
        _lastNotifiedNodeId == selected.id) {
      return;
    }
    _lastNotifiedNodeId = selected.id;
    widget.onPositionSelected?.call(
      EvalTreePositionSelection(
        fen: selected.fen,
        rootFen: snapshot.root.fen,
        movePathSan: snapshot.movePathSan(selected.id),
        rootStartMovesSan: snapshot.startMovesSan,
      ),
    );
  }

  String? _treePath() {
    final filePath = widget.currentRepertoire?.filePath;
    if (filePath == null || filePath.isEmpty) {
      return null;
    }
    final base = p.withoutExtension(filePath);
    return '${base}_tree.json';
  }
}

/// Everything `EvalTreeLayoutEngine.buildFrame` reads from the controller.
class _FrameKey {
  const _FrameKey({
    required this.snapshot,
    required this.selectedNodeId,
    required this.visiblePly,
    required this.showAncestorSpine,
    required this.maxDisplayNodes,
    required this.metricDisplayMode,
  });

  final EvalTreeSnapshot snapshot;
  final int? selectedNodeId;
  final int visiblePly;
  final bool showAncestorSpine;
  final int maxDisplayNodes;
  final EvalTreeMetricDisplayMode metricDisplayMode;

  @override
  bool operator ==(Object other) =>
      other is _FrameKey &&
      identical(other.snapshot, snapshot) &&
      other.selectedNodeId == selectedNodeId &&
      other.visiblePly == visiblePly &&
      other.showAncestorSpine == showAncestorSpine &&
      other.maxDisplayNodes == maxDisplayNodes &&
      other.metricDisplayMode == metricDisplayMode;

  @override
  int get hashCode => Object.hash(
    identityHashCode(snapshot),
    selectedNodeId,
    visiblePly,
    showAncestorSpine,
    maxDisplayNodes,
    metricDisplayMode,
  );
}

class _FrameMemo {
  const _FrameMemo(this.key, this.frame);
  final _FrameKey key;
  final EvalTreeLayoutFrame frame;
}

typedef _PreparedTree = ({
  EvalTreeSnapshot snapshot,
  EvalTreeLineMetricsCache metrics,
  int maxPly,
});

_PreparedTree _prepareTree(BuildTree tree, bool playAsWhite) {
  final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
    tree,
    playAsWhite: playAsWhite,
  );
  return (
    snapshot: snapshot,
    metrics: EvalTreeLineMetricsCache.fromSnapshot(snapshot),
    maxPly: tree.maxPlyReached,
  );
}

_PreparedTree _prepareSavedTree((String, bool) input) =>
    _prepareTree(deserializeTree(input.$1), input.$2);

_PreparedTree _prepareGeneratedTree((BuildTree, bool) input) =>
    _prepareTree(input.$1, input.$2);
