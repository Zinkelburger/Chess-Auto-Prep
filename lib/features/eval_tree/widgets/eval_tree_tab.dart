import 'dart:io' as io;

import 'package:flutter/material.dart';

import '../../../models/build_tree_node.dart';
import '../../../services/generation/tree_serialization.dart';
import '../../../utils/tree_colors.dart';
import '../adapters/eval_tree_snapshot_adapter.dart';
import '../controllers/eval_tree_controller.dart';
import '../models/eval_tree_snapshot.dart';
import '../services/eval_tree_layout_engine.dart';
import 'eval_tree_details_pane.dart';
import 'eval_tree_toolbar.dart';
import 'eval_tree_viewport.dart';

class EvalTreePositionSelection {
  static const String _standardFen =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  final String fen;
  final String rootFen;
  final List<String> movePathSan;
  final List<String> rootStartMovesSan;

  EvalTreePositionSelection({
    required this.fen,
    required this.rootFen,
    required List<String> movePathSan,
    required List<String> rootStartMovesSan,
  })  : movePathSan = List.unmodifiable(movePathSan),
        rootStartMovesSan = List.unmodifiable(rootStartMovesSan);

  List<String> get fullMovePathSan => [...rootStartMovesSan, ...movePathSan];

  String? get startingFen {
    if (rootStartMovesSan.isNotEmpty || rootFen == _standardFen) {
      return null;
    }
    return rootFen;
  }
}

class EvalTreeTab extends StatefulWidget {
  final Map<String, dynamic>? currentRepertoire;
  final bool isWhiteRepertoire;
  final BuildTree? generatedTree;
  final ValueChanged<EvalTreePositionSelection>? onPositionSelected;
  final ValueChanged<EvalTreeController?>? onControllerReady;

  const EvalTreeTab({
    super.key,
    required this.currentRepertoire,
    required this.isWhiteRepertoire,
    required this.generatedTree,
    this.onPositionSelected,
    this.onControllerReady,
  });

  @override
  State<EvalTreeTab> createState() => _EvalTreeTabState();
}

class _EvalTreeTabState extends State<EvalTreeTab>
    with AutomaticKeepAliveClientMixin {
  final EvalTreeController _controller = EvalTreeController();

  BuildTree? _tree;
  EvalTreeSnapshot? _snapshot;
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

    final oldPath = oldWidget.currentRepertoire?['filePath'] as String?;
    final newPath = widget.currentRepertoire?['filePath'] as String?;
    if (oldPath != newPath) {
      _dismissed = false;
      _lastNotifiedNodeId = null;
      _clearTreeState(notifySelection: false);
      _restoreInitialTree();
      return;
    }

    if (!identical(oldWidget.generatedTree, widget.generatedTree) &&
        widget.generatedTree != null) {
      _dismissed = false;
      _setTree(widget.generatedTree!, resetView: true);
    }
  }

  @override
  void dispose() {
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
              style: TextStyle(color: Colors.grey, fontSize: 14),
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

        final layoutFrame =
            EvalTreeLayoutEngine.buildFrame(snapshot, _controller);
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
                    flex: 2,
                    child: EvalTreeDetailsPane(
                      snapshot: snapshot,
                      controller: _controller,
                      currentNode: currentNode,
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    flex: 3,
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
    final message = _error ??
        (hasPath
            ? 'Generate a repertoire tree or load a saved tree file.'
            : 'Select a repertoire first.');

    return Container(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.insights, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            const Text(
              'No eval tree found',
              style: TextStyle(color: Colors.grey, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: hasPath ? _reloadFromFile : null,
              icon: const Icon(Icons.file_open),
              label: const Text('Load from file'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryBar(BuildContext context, EvalTreeSnapshot snapshot) {
    final maxDepth = _tree?.maxDepthReached ?? snapshot.root.subtreeDepth;
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
          Icon(Icons.insights, size: 16, color: Colors.grey[400]),
          Text(
            '${snapshot.nodeCount} nodes • depth $maxDepth',
            style: TextStyle(fontSize: 11, color: Colors.grey[400]),
          ),
          SizedBox(
            height: 28,
            child: TextButton.icon(
              onPressed: _reloadFromFile,
              icon: Icon(Icons.refresh, size: 14, color: Colors.grey[400]),
              label: Text(
                'Reload',
                style: TextStyle(fontSize: 11, color: Colors.grey[400]),
              ),
            ),
          ),
          SizedBox(
            height: 28,
            child: TextButton.icon(
              onPressed: () {
                setState(() {
                  _dismissed = true;
                });
                _clearTreeState(notifySelection: false);
              },
              icon: Icon(Icons.close, size: 14, color: Colors.grey[400]),
              label: Text(
                'Close',
                style: TextStyle(fontSize: 11, color: Colors.grey[400]),
              ),
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
        Text(label, style: TextStyle(fontSize: 9, color: Colors.grey[500])),
      ],
    );
  }

  void _restoreInitialTree() {
    if (widget.generatedTree != null) {
      _setTree(widget.generatedTree!, resetView: true);
      return;
    }
    if (_dismissed) return;
    _reloadFromFile(autoLoad: true);
  }

  Future<void> _reloadFromFile({bool autoLoad = false}) async {
    final path = _treePath();
    if (path == null || path.isEmpty) {
      return;
    }

    final file = io.File(path);
    if (!await file.exists()) {
      if (!autoLoad && mounted) {
        setState(() {
          _error = 'No tree file found. Generate a tree first.';
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final json = await file.readAsString();
      final tree = deserializeTree(json);
      if (!mounted) return;
      _setTree(tree, resetView: true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Failed to load tree: $error';
      });
    }
  }

  void _setTree(BuildTree tree, {required bool resetView}) {
    final snapshot = EvalTreeSnapshotAdapter.fromBuildTree(
      tree,
      playAsWhite: widget.isWhiteRepertoire,
    );
    setState(() {
      _tree = tree;
      _snapshot = snapshot;
      _isLoading = false;
      _error = null;
    });
    _controller.loadSnapshot(snapshot, resetView: resetView);
  }

  void _clearTreeState({required bool notifySelection}) {
    setState(() {
      _tree = null;
      _snapshot = null;
      _isLoading = false;
      _error = null;
    });
    _controller.clearSnapshot();
    if (notifySelection) {
      _lastNotifiedNodeId = null;
    }
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
    final filePath = widget.currentRepertoire?['filePath'] as String?;
    if (filePath == null || filePath.isEmpty) {
      return null;
    }
    final base = filePath.toLowerCase().endsWith('.pgn')
        ? filePath.substring(0, filePath.length - 4)
        : filePath;
    return '${base}_tree.json';
  }
}
