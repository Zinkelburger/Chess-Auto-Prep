/// The Tree surface of the repertoire builder: the repertoire's own opening
/// tree, with the live Lichess opening explorer optionally split in beneath
/// it.
///
/// This owns the explorer rather than the screen does, for one reason worth
/// stating: [LiveExplorerService] holds an HTTP client and a debounce timer,
/// and the screen was creating it lazily on first toggle while disposing it
/// from its own `dispose` — a lifetime spread across two files. Here the pane
/// creates it and the pane disposes it.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/explorer_response.dart';
import '../../../models/opening_tree.dart';
import '../../../models/repertoire_line.dart';
import '../../../services/live_explorer_service.dart';
import '../../../widgets/opening_explorer/opening_explorer_panel.dart';
import '../../../widgets/opening_tree_widget.dart';

class RepertoireTreePane extends StatefulWidget {
  const RepertoireTreePane({
    super.key,
    required this.tree,
    required this.repertoireLines,
    required this.currentMoveSequence,
    required this.fen,
    required this.onMoveSelected,
    required this.onGoBack,
    required this.onGoForward,
    required this.repertoireMovesAtPosition,
    required this.onPlayMove,
    required this.onAddMove,
    this.onHoverTreeMove,
    this.onHoverExplorerMove,
  });

  /// SAN under the pointer in the repertoire tree (null on leave), for an
  /// arrow on the board.
  final ValueChanged<String?>? onHoverTreeMove;

  /// Explorer move under the pointer (null on leave), likewise.
  final ValueChanged<ExplorerMove?>? onHoverExplorerMove;

  /// The repertoire's tree, or null before one is loaded.
  final OpeningTree? tree;
  final List<RepertoireLine> repertoireLines;
  final List<String> currentMoveSequence;

  /// Position the explorer looks up.
  final String fen;

  final ValueChanged<String> onMoveSelected;
  final VoidCallback onGoBack;
  final VoidCallback onGoForward;

  /// SANs already in the repertoire at [fen]. A callback so the walk only
  /// happens while the explorer is actually open.
  final ValueGetter<Set<String>> repertoireMovesAtPosition;

  final ValueChanged<String> onPlayMove;
  final ValueChanged<ExplorerMove> onAddMove;

  /// Smallest usable height for the tree above and the explorer below.
  static const double minTreeHeight = 80;
  static const double minExplorerHeight = 140;
  static const double handleHeight = 10;

  /// Height of the tree half when the explorer is split in below it.
  ///
  /// Both halves have a minimum, but a pane too short to honour both cannot
  /// be split by clamping — asking for that inverts the bounds and throws, so
  /// the ratio applies unbounded there instead.
  static double treeHeightFor(double available, double ratio) {
    if (available <= minTreeHeight + minExplorerHeight) {
      return available * ratio;
    }
    return (available * ratio)
        .clamp(minTreeHeight, available - minExplorerHeight)
        .toDouble();
  }

  @override
  State<RepertoireTreePane> createState() => _RepertoireTreePaneState();
}

class _RepertoireTreePaneState extends State<RepertoireTreePane> {
  /// Created on first open so the API service only exists once the user asks
  /// for it.
  LiveExplorerService? _explorer;
  bool _showExplorer = false;

  /// Fraction of the pane given to the tree when the explorer is open.
  double _splitRatio = 0.6;

  @override
  void dispose() {
    _explorer?.dispose();
    super.dispose();
  }

  void _toggleExplorer() {
    setState(() {
      _showExplorer = !_showExplorer;
      if (_showExplorer) {
        _explorer ??= LiveExplorerService();
      } else {
        _explorer?.reset();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tree = widget.tree;
    final Widget treeArea = tree == null
        ? const Center(
            child: Text(
              'No opening tree available.\nLoad a repertoire to build the tree.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          )
        : OpeningTreeWidget(
            tree: tree,
            repertoireLines: widget.repertoireLines,
            currentMoveSequence: widget.currentMoveSequence,
            onMoveSelected: widget.onMoveSelected,
            onGoBack: widget.onGoBack,
            onGoForward: widget.onGoForward,
            onHoverMove: widget.onHoverTreeMove,
          );

    return Column(
      children: [
        _buildToolbar(context),
        const Divider(height: 1),
        Expanded(child: _showExplorer ? _buildSplit(treeArea) : treeArea),
      ],
    );
  }

  /// Header above the tree with the Lichess-style book toggle that reveals
  /// the live opening explorer beneath it.
  Widget _buildToolbar(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          const SizedBox(width: 8),
          Text(
            'Repertoire tree',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.grey[400],
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(
              _showExplorer ? Icons.menu_book : Icons.menu_book_outlined,
              size: 16,
            ),
            color: _showExplorer ? theme.colorScheme.primary : null,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            tooltip: _showExplorer
                ? 'Hide opening explorer'
                : 'Show Lichess opening explorer',
            onPressed: _toggleExplorer,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildSplit(Widget treeArea) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = math.max(
          0.0,
          constraints.maxHeight - RepertoireTreePane.handleHeight,
        );
        return Column(
          children: [
            SizedBox(
              height: RepertoireTreePane.treeHeightFor(available, _splitRatio),
              child: treeArea,
            ),
            _buildSplitHandle(available),
            Expanded(child: _buildExplorerPanel()),
          ],
        );
      },
    );
  }

  Widget _buildSplitHandle(double available) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) {
          if (available <= 0) return;
          setState(() {
            _splitRatio = (_splitRatio + d.delta.dy / available).clamp(
              0.15,
              0.85,
            );
          });
        },
        child: Container(
          height: RepertoireTreePane.handleHeight,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          alignment: Alignment.center,
          child: Container(
            width: 28,
            height: 3,
            decoration: BoxDecoration(
              color: Colors.grey[600],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExplorerPanel() {
    return OpeningExplorerPanel(
      service: _explorer!,
      fen: widget.fen,
      movePath: widget.currentMoveSequence,
      repertoireMovesAtPosition: widget.repertoireMovesAtPosition(),
      onPlayMove: widget.onPlayMove,
      onAddMove: widget.onAddMove,
      onHoverMove: widget.onHoverExplorerMove,
    );
  }
}
