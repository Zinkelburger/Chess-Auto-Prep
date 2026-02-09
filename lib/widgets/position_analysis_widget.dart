/// Position analysis widget – three-panel layout for the Player Analysis screen.
///
/// Left: FEN list (or loading spinner). Centre: chess board. Right: tabbed pane.
/// Always renders the full layout – never collapses to a centred placeholder.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chess/chess.dart' as chess;

import '../models/position_analysis.dart';
import '../models/opening_tree.dart';
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

  const PositionAnalysisWidget({
    super.key,
    this.analysis,
    this.openingTree,
    this.playerIsWhite,
    this.isLoading = false,
    this.onAnalyze,
  });

  @override
  State<PositionAnalysisWidget> createState() =>
      _PositionAnalysisWidgetState();
}

class _PositionAnalysisWidgetState extends State<PositionAnalysisWidget>
    with SingleTickerProviderStateMixin {
  chess.Chess? _currentBoard;
  String? _currentFen;
  GameInfo? _selectedGame;
  late TabController _tabController;
  List<GameInfo> _currentGames = [];
  final PgnViewerController _pgnController = PgnViewerController();

  /// Starting-position board, shown when no FEN has been selected yet.
  static final chess.Chess _startingPosition = chess.Chess();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────

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
                    onMove: null,
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

  // ── Key handler ────────────────────────────────────────────────────

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Move Tree tab (index 0): arrow keys navigate the tree.
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

    // PGN tab (index 2): arrow keys navigate the PGN.
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

  // ── Left panel ─────────────────────────────────────────────────────

  Widget _buildLeftPanel() {
    if (widget.analysis != null) {
      return FenListWidget(
        analysis: widget.analysis!,
        onFenSelected: _onFenSelected,
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

  // ── Right panel ────────────────────────────────────────────────────

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
              // ── Move Tree tab ──
              _buildMoveTreeTab(),

              // ── Games tab ──
              GamesListWidget(
                games: _currentGames,
                currentFen: _currentFen,
                onGameSelected: _onGameSelected,
              ),

              // ── PGN tab ──
              _selectedGame != null && _selectedGame!.pgnText != null
                  ? PgnViewerWidget(
                      pgnText: _selectedGame!.pgnText!,
                      controller: _pgnController,
                      onPositionChanged: (position) {
                        try {
                          setState(() {
                            _currentBoard =
                                chess.Chess.fromFEN(position.fen);
                          });
                        } catch (_) {}
                      },
                    )
                  : const Center(
                      child: Text(
                        'Select a game to view PGN',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
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
        // ── Back button + breadcrumb ──
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
        // ── Tree widget ──
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

  // ── Tree navigation ────────────────────────────────────────────────

  /// Advance the tree to a child by SAN move, update board + games.
  void _onTreeMoveSelected(String move) {
    final tree = widget.openingTree;
    if (tree == null) return;

    if (tree.makeMove(move)) {
      _syncBoardToTree();
    }
  }

  /// Go back one move in the tree.
  void _treeGoBack() {
    final tree = widget.openingTree;
    if (tree == null) return;

    if (tree.goBack()) {
      _syncBoardToTree();
    }
  }

  /// Advance to the most-played child (main line).
  void _treeGoForward() {
    final tree = widget.openingTree;
    if (tree == null) return;

    final children = tree.currentNode.sortedChildren;
    if (children.isNotEmpty) {
      tree.makeMove(children.first.move);
      _syncBoardToTree();
    }
  }

  /// Sync the board, FEN, and games list to the tree's current position.
  void _syncBoardToTree() {
    final tree = widget.openingTree;
    if (tree == null) return;

    setState(() {
      _currentFen = tree.currentNode.fen;
      _currentBoard = _parseFen(tree.currentNode.fen);
      _selectedGame = null;

      if (widget.analysis != null) {
        _currentGames = widget.analysis!.getGamesForFen(tree.currentNode.fen);
      }
    });
  }

  // ── FEN list selection ─────────────────────────────────────────────

  void _onFenSelected(String fen) {
    setState(() {
      _currentFen = fen;
      _currentBoard = _parseFen(fen);
      _selectedGame = null;

      if (widget.analysis != null) {
        _currentGames = widget.analysis!.getGamesForFen(fen);
      }
    });

    // Navigate the tree to this position so its children are visible.
    widget.openingTree?.navigateToFen(fen);

    // Default to Move Tree tab so the user sees continuations immediately.
    _tabController.animateTo(0);
  }

  /// Legacy FEN callback from the tree widget (fires alongside onMoveSelected).
  /// Board sync is already handled by [_onTreeMoveSelected], so this is a
  /// no-op to avoid double updates.
  void _onTreePositionSelected(String fen) {
    // Intentionally empty – navigation is driven by _onTreeMoveSelected.
  }

  void _onGameSelected(GameInfo game) {
    setState(() => _selectedGame = game);
    _tabController.animateTo(2);
  }

  // ── Helpers ────────────────────────────────────────────────────────

  static chess.Chess? _parseFen(String fen) {
    try {
      String fullFen = fen;
      if (fen.split(' ').length == 4) {
        fullFen = '$fen 0 1';
      }
      return chess.Chess.fromFEN(fullFen);
    } catch (_) {
      return null;
    }
  }
}
