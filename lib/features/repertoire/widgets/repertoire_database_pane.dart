/// Shared database surface for repertoire continuations and opening practice.
/// The pane owns and disposes its live explorer client and debounce timer.
library;

import 'package:flutter/material.dart';

import '../../../models/explorer_response.dart';
import '../../../models/opening_tree.dart';
import '../../../models/repertoire_line.dart';
import '../../../widgets/opening_tree_widget.dart';
import '../../../services/live_explorer_service.dart';
import '../../../widgets/opening_explorer/opening_explorer_panel.dart';

class RepertoireDatabasePane extends StatefulWidget {
  const RepertoireDatabasePane({
    super.key,
    required this.fen,
    required this.currentMoveSequence,
    required this.repertoireMovesAtPosition,
    required this.onPlayMove,
    this.tree,
    this.repertoireLines = const [],
    this.onHoverTreeMove,
    this.onGoBack,
    this.onGoForward,
    this.onAddMove,
    this.onHoverMove,
  });

  /// Position the explorer looks up.
  final String fen;
  final OpeningTree? tree;
  final List<RepertoireLine> repertoireLines;
  final ValueChanged<String?>? onHoverTreeMove;
  final VoidCallback? onGoBack;
  final VoidCallback? onGoForward;

  /// SAN path to [fen].
  final List<String> currentMoveSequence;

  /// SANs already in the repertoire at [fen]; a callback so the walk only
  /// happens while this tab is actually built.
  final ValueGetter<Set<String>> repertoireMovesAtPosition;

  final ValueChanged<String> onPlayMove;

  /// Right-click "add to repertoire"; null where there is no repertoire to
  /// add to (the planner).
  final ValueChanged<ExplorerMove>? onAddMove;

  /// Hovered explorer move (null on leave), for an arrow on the board.
  final ValueChanged<ExplorerMove?>? onHoverMove;

  @override
  State<RepertoireDatabasePane> createState() => _RepertoireDatabasePaneState();
}

class _RepertoireDatabasePaneState extends State<RepertoireDatabasePane> {
  bool _repertoire = true;
  late final LiveExplorerService _explorer = LiveExplorerService();

  @override
  void dispose() {
    _explorer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Repertoire')),
              ButtonSegment(value: false, label: Text('Opening explorer')),
            ],
            selected: {_repertoire},
            onSelectionChanged: (v) {
              if (mounted) setState(() => _repertoire = v.first);
            },
          ),
        ),
        Expanded(
          child: _repertoire
              ? widget.tree == null
                    ? const Center(child: Text('No repertoire moves yet'))
                    : OpeningTreeWidget(
                        tree: widget.tree!,
                        repertoireLines: widget.repertoireLines,
                        currentMoveSequence: widget.currentMoveSequence,
                        onMoveSelected: widget.onPlayMove,
                        onGoBack: widget.onGoBack,
                        onGoForward: widget.onGoForward,
                        onHoverMove: widget.onHoverTreeMove,
                        showCopyMoves: false,
                      )
              : OpeningExplorerPanel(
                  service: _explorer,
                  fen: widget.fen,
                  movePath: widget.currentMoveSequence,
                  repertoireMovesAtPosition: widget.repertoireMovesAtPosition(),
                  onPlayMove: widget.onPlayMove,
                  onAddMove: widget.onAddMove,
                  onHoverMove: widget.onHoverMove,
                ),
        ),
      ],
    );
  }
}
