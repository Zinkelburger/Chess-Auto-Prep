/// Shared database surface for repertoire continuations and opening practice.
/// The pane owns and disposes its live explorer client and debounce timer.
library;

import 'package:chess_auto_prep/chess_core/moves/opening_graph.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../controllers/repertoire_layout_prefs.dart';
import '../../../models/explorer_response.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/master_games_prompt_banner.dart';
import 'local_reference_pane.dart';
import 'reference_game_dialog.dart';
import '../../../services/explorer_game_opener.dart';
import '../../../models/pgn_game_entry.dart';
import '../../../chess_core/pgn/pgn_text.dart';
import '../../../utils/app_messages.dart';
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
    this.source,
    this.onSourceChanged,
    this.evaluationsBuilder,
    this.repertoireLines = const [],
    this.onHoverTreeMove,
    this.onGoBack,
    this.onGoForward,
    this.onAddMove,
    this.onHoverMove,
  });

  /// Position the explorer looks up.
  final String fen;
  final int? source;
  final ValueChanged<int>? onSourceChanged;
  final Widget Function(Widget sourceMenu, bool chessDb)? evaluationsBuilder;
  final OpeningGraph? tree;
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
  int _selectedSource = 0;
  int get _source => widget.source ?? _selectedSource;
  late final LiveExplorerService _explorer = LiveExplorerService();

  @override
  void initState() {
    super.initState();
    if (widget.source == null) unawaited(_restoreSource());
  }

  Future<void> _restoreSource() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final source = prefs.getInt(RepertoireLayoutPrefs.databaseSourceKey);
      // Engine evals and ChessDB are only reachable when the host supplies
      // their builder; restoring one without it would label the pane for a
      // source it cannot show.
      final maxSource = widget.evaluationsBuilder == null
          ? 2
          : RepertoireLayoutPrefs.maxDatabaseSource;
      if (mounted && source != null && source >= 0 && source <= maxSource) {
        setState(() => _selectedSource = source);
      }
    } catch (_) {
      // Source preferences are best-effort.
    }
  }

  Future<void> _selectSource(int source) async {
    if (!mounted) return;
    setState(() => _selectedSource = source);
    widget.onHoverMove?.call(null);
    widget.onHoverTreeMove?.call(null);
    widget.onSourceChanged?.call(source);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(RepertoireLayoutPrefs.databaseSourceKey, source);
    } catch (_) {}
  }

  @override
  void dispose() {
    _explorer.dispose();
    super.dispose();
  }

  Future<void> _openGame(ExplorerGame game) async {
    final fen = widget.fen;
    try {
      final pgn = await ExplorerGameOpener().fetchPgn(game);
      if (pgn == null) throw StateError('Game is unavailable');
      if (!mounted) return;
      await showReferenceGame(
        context,
        PgnGameEntry(headers: extractHeaders(pgn), pgnText: pgn),
        fen,
      );
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Could not open game: $e', isError: true);
      }
    }
  }

  Widget _sourceMenu() => PopupMenuButton<int>(
    tooltip: 'Database source',
    initialValue: _source,
    onSelected: (source) => unawaited(_selectSource(source)),
    itemBuilder: (_) => [
      if (widget.evaluationsBuilder != null) ...[
        const PopupMenuItem(value: 3, child: Text('Engine evals')),
        const PopupMenuItem(value: 4, child: Text('ChessDB')),
      ],
      const PopupMenuItem(value: 0, child: Text('Repertoire')),
      const PopupMenuItem(value: 1, child: Text('Opening explorer')),
      const PopupMenuItem(value: 2, child: Text('Local PGN')),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              const [
                'Repertoire',
                'Opening explorer',
                'Local PGN',
                'Engine evals',
                'ChessDB',
              ][_source],
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body,
            ),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_source >= 3 && widget.evaluationsBuilder != null) {
      return widget.evaluationsBuilder!(_sourceMenu(), _source == 4);
    }
    return Column(
      children: [
        Align(alignment: Alignment.centerLeft, child: _sourceMenu()),
        if (_source == 1 || _source == 2) const MasterGamesPromptBanner(),
        Expanded(
          child: _source == 0
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
              : _source == 2
              ? LocalReferencePane(
                  fen: widget.fen,
                  onPlayMove: widget.onPlayMove,
                  onAddMove: widget.onAddMove,
                  onHoverMove: widget.onHoverMove,
                  repertoireMoves: widget.repertoireMovesAtPosition(),
                )
              : OpeningExplorerPanel(
                  service: _explorer,
                  sideBySideGames: false,
                  onOpenGame: _openGame,
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
