/// The Database tab of the analysis panel: the live Lichess opening explorer
/// for the position on the board, as a first-class peer of the engine rather
/// than a toggle hidden inside the tree.
///
/// Owns its [LiveExplorerService] the way [RepertoireTreePane] does — the
/// service holds an HTTP client and a debounce timer, so the widget that
/// shows its results is the one that creates and disposes it.
library;

import 'package:flutter/material.dart';

import '../../../models/explorer_response.dart';
import '../../../services/live_explorer_service.dart';
import '../../../widgets/opening_explorer/opening_explorer_panel.dart';

class RepertoireDatabasePane extends StatefulWidget {
  const RepertoireDatabasePane({
    super.key,
    required this.fen,
    required this.repertoireMovesAtPosition,
    required this.onPlayMove,
    required this.onAddMove,
  });

  /// Position the explorer looks up.
  final String fen;

  /// SANs already in the repertoire at [fen]; a callback so the walk only
  /// happens while this tab is actually built.
  final ValueGetter<Set<String>> repertoireMovesAtPosition;

  final ValueChanged<String> onPlayMove;
  final ValueChanged<ExplorerMove> onAddMove;

  @override
  State<RepertoireDatabasePane> createState() => _RepertoireDatabasePaneState();
}

class _RepertoireDatabasePaneState extends State<RepertoireDatabasePane> {
  late final LiveExplorerService _explorer = LiveExplorerService();

  @override
  void dispose() {
    _explorer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OpeningExplorerPanel(
      service: _explorer,
      fen: widget.fen,
      repertoireMovesAtPosition: widget.repertoireMovesAtPosition(),
      onPlayMove: widget.onPlayMove,
      onAddMove: widget.onAddMove,
    );
  }
}
