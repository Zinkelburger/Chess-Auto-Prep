part of 'position_analysis_widget.dart';

// =====================================================================
// Central navigation — single source of truth
// =====================================================================

/// Central [_navigateTo] plus the per-source event handlers that funnel
/// through it so board, tree, games list and PGN viewer stay in sync.
mixin _NavigationMixin on _PositionAnalysisWidgetStateBase {
  /// Navigate to a position.  **Every** position change from any source
  /// (board, tree, FEN list, PGN) must flow through here so all panels
  /// stay in sync.
  @override
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

  /// Board drag: try to advance the game tree; off-book moves (or any move
  /// while the Analysis tab is active) land in the scratch tree.
  void _onBoardMove(CompletedMove move) {
    final preFen = _currentFen ?? _startingPosition.fen;
    final tree = widget.openingTree;
    var inBook = false;
    if (tree != null) {
      // Try the move by SAN first (keeps tree cursor aligned) — but only when
      // the cursor actually sits on the pre-move position; a stale cursor
      // (earlier FEN jump failed) could otherwise claim an off-book move as
      // in-book and silently drop it from the Analysis workspace.
      final cursorSynced =
          normalizeFen(tree.currentNode.fen) == normalizeFen(preFen);
      inBook = cursorSynced && tree.makeMove(move.san);
      if (!inBook) {
        // Out of book — best-effort FEN jump.
        tree.navigateToFen(move.fenAfter);
      }
    }
    final analysisTabActive = _tabController.index == _kAnalysisTabIndex;
    if (!inBook || analysisTabActive) {
      _recordScratchMove(preFen, move.san);
      if (!inBook && !analysisTabActive) {
        _tabController.animateTo(_kAnalysisTabIndex);
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

  /// Tree header: click a move in the current line → jump to that ply.
  /// Ply 0 is the root (starting position).
  void _onTreePathPlySelected(int ply) {
    final tree = widget.openingTree;
    if (tree == null) return;
    while (tree.currentDepth > ply) {
      if (!tree.goBack()) break;
    }
    _navigateTo(tree.currentNode.fen);
  }

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
}
