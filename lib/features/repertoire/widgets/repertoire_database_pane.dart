/// Shared database surface for repertoire continuations and opening practice.
/// The pane owns and disposes its live explorer client and debounce timer.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/explorer_response.dart';
import '../../../theme/app_text_styles.dart';
import 'local_reference_pane.dart';
import 'reference_game_dialog.dart';
import '../../../services/explorer_game_opener.dart';
import '../../../models/pgn_game_entry.dart';
import '../../../services/pgn_parsing_service.dart';
import '../../../utils/app_messages.dart';
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
  int _source = 0;
  late final LiveExplorerService _explorer = LiveExplorerService();

  @override
  void initState() {
    super.initState();
    unawaited(_restoreSource());
  }

  Future<void> _restoreSource() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final source = prefs.getInt('repertoire.reference_source');
      if (mounted && source != null && source >= 0 && source <= 2) {
        setState(() => _source = source);
      }
    } catch (_) {
      // Source preferences are best-effort.
    }
  }

  Future<void> _selectSource(int source) async {
    if (!mounted) return;
    setState(() => _source = source);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('repertoire.reference_source', source);
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: [
                if (constraints.maxWidth >= 550) ...[
                  const Icon(Icons.storage_outlined, size: 16),
                  const SizedBox(width: 8),
                  const Text('Reference database', style: AppTextStyles.muted),
                  const Spacer(),
                ],
                Flexible(
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    segments: const [
                      ButtonSegment(value: 0, label: Text('Repertoire')),
                      ButtonSegment(value: 1, label: Text('Opening explorer')),
                      ButtonSegment(value: 2, label: Text('Local PGN')),
                    ],
                    selected: {_source},
                    onSelectionChanged: (v) {
                      unawaited(_selectSource(v.first));
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
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
                  sideBySideGames: true,
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
