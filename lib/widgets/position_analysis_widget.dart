/// Position analysis widget – three-panel layout for the Player Analysis screen.
///
/// Left: FEN list (or loading spinner). Centre: chess board. Right: tabbed pane.
///
/// All position changes from *any* source (board drag, tree click, FEN list,
/// PGN navigation) funnel through [_navigateTo] so the board, move tree,
/// games list and PGN viewer always stay in sync.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chess/chess.dart' as chess;

import '../models/position_analysis.dart';
import '../models/opening_tree.dart';
import '../utils/fen_utils.dart';
import '../widgets/fen_list_widget.dart';
import '../widgets/games_list_widget.dart';
import '../widgets/opening_tree_widget.dart';
import 'chess_board_widget.dart';
import 'pgn_viewer_widget.dart';

class PositionAnalysisWidget extends StatefulWidget {
  final PositionAnalysis? analysis;
  final OpeningTree? openingTree;
  final bool? playerIsWhite;
  final bool isLoading;
  final Function()? onAnalyze;

  /// Whether engine eval data is available for the "Bad Eval" sort.
  final bool hasEvals;

  /// When set (and [externalNavigateGeneration] changes), the widget
  /// navigates to this FEN.  Used by the engine-weakness dialog.
  final String? externalNavigateFen;
  final int externalNavigateGeneration;

  const PositionAnalysisWidget({
    super.key,
    this.analysis,
    this.openingTree,
    this.playerIsWhite,
    this.isLoading = false,
    this.onAnalyze,
    this.hasEvals = false,
    this.externalNavigateFen,
    this.externalNavigateGeneration = 0,
  });

  @override
  State<PositionAnalysisWidget> createState() =>
      _PositionAnalysisWidgetState();
}

class _PositionAnalysisWidgetState extends State<PositionAnalysisWidget>
    with SingleTickerProviderStateMixin {
  // ── Canonical position state ───────────────────────────────────────
  //
  // Every position change flows through [_navigateTo], which updates
  // all four of these in a single setState call.

  String? _currentFen;
  chess.Chess? _currentBoard;
  List<GameInfo> _currentGames = [];
  GameInfo? _selectedGame;

  late TabController _tabController;
  final PgnViewerController _pgnController = PgnViewerController();
  int _lastNavigateGeneration = 0;

  /// Starting-position board, shown when no FEN has been selected yet.
  static final chess.Chess _startingPosition = chess.Chess();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void didUpdateWidget(PositionAnalysisWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.externalNavigateFen != null &&
        widget.externalNavigateGeneration != _lastNavigateGeneration) {
      _lastNavigateGeneration = widget.externalNavigateGeneration;
      widget.openingTree?.navigateToFen(widget.externalNavigateFen!);
      _navigateTo(widget.externalNavigateFen!);
      _tabController.animateTo(0);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // =====================================================================
  // Build
  // =====================================================================

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Row(
        children: [
          // ── Left panel: FEN list or loading state ──
          SizedBox(width: 300, child: _buildLeftPanel()),

          Container(width: 1, color: Colors.grey[700]),

          // ── Centre panel: chess board ──
          Expanded(
            flex: 3,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: ChessBoardWidget(
                    game: _currentBoard ?? _startingPosition,
                    flipped: widget.playerIsWhite != null
                        ? !widget.playerIsWhite!
                        : false,
                    onMove: _onBoardMove,
                  ),
                ),
              ),
            ),
          ),

          Container(width: 1, color: Colors.grey[700]),

          // ── Right panel: tabs ──
          SizedBox(width: 350, child: _buildRightPanel()),
        ],
      ),
    );
  }

  // =====================================================================
  // Keyboard navigation
  // =====================================================================

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Move Tree tab: arrow keys navigate the tree.
    if (_tabController.index == 0 && widget.openingTree != null) {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        _treeGoBack();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _treeGoForward();
        return KeyEventResult.handled;
      }
    }

    // PGN tab: arrow keys navigate the PGN.
    if (_tabController.index == 2) {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        _pgnController.goBack();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _pgnController.goForward();
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  // =====================================================================
  // Left panel
  // =====================================================================

  Widget _buildLeftPanel() {
    if (widget.analysis != null) {
      return FenListWidget(
        analysis: widget.analysis!,
        onFenSelected: _onFenSelected,
        playerIsWhite: widget.playerIsWhite ?? true,
        hasEvals: widget.hasEvals,
      );
    }

    if (widget.isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              'Analyzing positions…',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return const Center(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Select a player to begin',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      ),
    );
  }

  // =====================================================================
  // Right panel (tabs)
  // =====================================================================

  Widget _buildRightPanel() {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Move Tree'),
            Tab(text: 'Games'),
            Tab(text: 'PGN'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildMoveTreeTab(),
              GamesListWidget(
                games: _currentGames,
                currentFen: _currentFen,
                onGameSelected: _onGameSelected,
              ),
              _buildPgnTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMoveTreeTab() {
    if (widget.openingTree == null) {
      return const Center(
        child: Text(
          'Opening tree not available',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final tree = widget.openingTree!;
    final canGoBack = tree.currentNode.parent != null;

    return Column(
      children: [
        if (canGoBack)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _treeGoBack,
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Back', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        Expanded(
          child: OpeningTreeWidget(
            tree: tree,
            onMoveSelected: _onTreeMoveSelected,
            onPositionSelected: _onTreePositionSelected,
          ),
        ),
      ],
    );
  }

  Widget _buildPgnTab() {
    if (_selectedGame == null || _selectedGame!.pgnText == null) {
      return const Center(
        child: Text(
          'Select a game to view PGN',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return PgnViewerWidget(
      pgnText: _selectedGame!.pgnText!,
      controller: _pgnController,
      initialFen: _currentFen,
      onPositionChanged: (position) => _onPgnPositionChanged(position.fen),
    );
  }

  // =====================================================================
  // Central navigation — single source of truth
  // =====================================================================

  /// Navigate to a position.  **Every** position change from any source
  /// (board, tree, FEN list, PGN) must flow through here so all panels
  /// stay in sync.
  void _navigateTo(String fen) {
    setState(() {
      _currentFen = fen;
      _currentBoard = _parseFen(fen);
      _selectedGame = null;
      _currentGames = widget.analysis?.getGamesForFen(fen) ?? [];
    });
  }

  // =====================================================================
  // Event handlers — each handler does its own tree logic, then calls
  // _navigateTo for the canonical state update.
  // =====================================================================

  /// Board drag: try to advance the tree, then navigate.
  void _onBoardMove(CompletedMove move) {
    final tree = widget.openingTree;
    if (tree != null) {
      // Try the move by SAN first (keeps tree cursor aligned).
      if (!tree.makeMove(move.san)) {
        // Out of book — best-effort FEN jump.
        tree.navigateToFen(move.fenAfter);
      }
    }
    _navigateTo(move.fenAfter);
  }

  /// Tree: click a move.
  void _onTreeMoveSelected(String move) {
    final tree = widget.openingTree;
    if (tree == null) return;
    if (tree.makeMove(move)) {
      _navigateTo(tree.currentNode.fen);
    }
  }

  /// Tree: legacy FEN callback (no-op; navigation driven by move handler).
  void _onTreePositionSelected(String fen) {}

  /// Tree: go back one move.
  void _treeGoBack() {
    final tree = widget.openingTree;
    if (tree == null) return;
    if (tree.goBack()) {
      _navigateTo(tree.currentNode.fen);
    }
  }

  /// Tree: advance to the most-played child (main line).
  void _treeGoForward() {
    final tree = widget.openingTree;
    if (tree == null) return;
    final children = tree.currentNode.sortedChildren;
    if (children.isNotEmpty) {
      tree.makeMove(children.first.move);
      _navigateTo(tree.currentNode.fen);
    }
  }

  /// FEN list (left panel): click a position.
  void _onFenSelected(String fen) {
    widget.openingTree?.navigateToFen(fen);
    _navigateTo(fen);
    _tabController.animateTo(0);
  }

  /// PGN viewer: user stepped through moves.
  void _onPgnPositionChanged(String fen) {
    widget.openingTree?.navigateToFen(fen);

    // Update board and games, but don't clear the selected game (the user
    // is still watching it).
    setState(() {
      _currentFen = fen;
      _currentBoard = _parseFen(fen);
      _currentGames = widget.analysis?.getGamesForFen(fen) ?? [];
    });
  }

  /// Games list: click a game → switch to PGN tab.
  void _onGameSelected(GameInfo game) {
    setState(() => _selectedGame = game);
    _tabController.animateTo(2);
  }

  // =====================================================================
  // Helpers
  // =====================================================================

  /// Parse a (possibly 4-field) FEN into a [chess.Chess] instance.
  static chess.Chess? _parseFen(String fen) {
    try {
      return chess.Chess.fromFEN(expandFen(fen));
    } catch (_) {
      return null;
    }
  }
}
