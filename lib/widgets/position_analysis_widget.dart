/// Position analysis widget – three-panel layout for the Player Analysis screen.
///
/// Left: FEN list (or loading spinner). Centre: chess board with an action
/// bar (study / puzzle / PGN-viewer handoffs). Right: engine bar + tabbed pane
/// (Move Tree · Games · PGN · Analysis · Holes).
///
/// All position changes from *any* source (board drag, tree click, FEN list,
/// PGN navigation, scratch-tree click, engine line click) funnel through
/// [_navigateTo] so the board, move tree, games list and PGN viewer always
/// stay in sync.
///
/// The **Analysis tab** holds a scratch [MoveTree] (same editor as Study
/// mode): off-book board moves land there as variations instead of
/// dead-ending, engine PV clicks append there, and the result can be saved
/// to a study chapter.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartchess/dartchess.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/study_controller.dart';
import '../features/audit/models/audit_finding.dart';
import '../features/audit/models/audit_result.dart';
import '../features/holes/services/hole_hunt_service.dart';
import '../features/holes/widgets/holes_report_panel.dart';
import '../models/move_tree.dart';
import '../models/position_analysis.dart';
import '../models/opening_tree.dart';
import '../services/storage/storage_factory.dart';
import '../utils/app_messages.dart';
import '../utils/fen_utils.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/fen_list_widget.dart';
import '../widgets/games_list_widget.dart';
import '../widgets/opening_tree_widget.dart';
import 'chess_board_widget.dart';
import 'engine/inline_engine_bar.dart';
import 'interactive_pgn_editor.dart';
import 'pgn/add_to_study_dialog.dart';
import 'pgn_viewer_widget.dart';

class PositionAnalysisWidget extends StatefulWidget {
  final PositionAnalysis? analysis;
  final OpeningTree? openingTree;
  final bool? playerIsWhite;
  final bool isLoading;
  final Function()? onAnalyze;

  /// Whether engine eval data is available for the "Bad Eval" sort.
  final bool hasEvals;

  /// Analyzed player's username — used in generated study-chapter names and
  /// stats comments.
  final String? playerName;

  /// Path to the player's downloaded games PGN — enables "Open Games in
  /// PGN Viewer".
  final String? analysisPgnPath;

  /// When set (and [externalNavigateGeneration] changes), the widget
  /// navigates to this FEN.  Used by the engine-weakness dialog.
  final String? externalNavigateFen;
  final int externalNavigateGeneration;

  // ── Hole hunt (Holes tab) — state owned by the host screen ──────────

  /// Completed hole-hunt report for the displayed colour, if any.
  final AuditResult? holesResult;

  /// Findings streamed from an in-flight hunt on the displayed colour.
  final List<AuditFinding> holesLiveFindings;

  /// True while a hunt is running on the displayed colour's tree.
  final bool isHoleHunting;
  final HoleHuntProgress? holesProgress;

  /// Show the "trap search skipped" note (Maia unavailable).
  final bool holesTrapPassSkipped;

  /// Re-persist after dismissal edits in the report panel.
  final void Function(AuditResult result)? onHolesResultChanged;

  /// Open the hunt config to start (or re-run) a hunt.
  final VoidCallback? onStartHoleHunt;

  const PositionAnalysisWidget({
    super.key,
    this.analysis,
    this.openingTree,
    this.playerIsWhite,
    this.isLoading = false,
    this.onAnalyze,
    this.hasEvals = false,
    this.playerName,
    this.analysisPgnPath,
    this.externalNavigateFen,
    this.externalNavigateGeneration = 0,
    this.holesResult,
    this.holesLiveFindings = const [],
    this.isHoleHunting = false,
    this.holesProgress,
    this.holesTrapPassSkipped = false,
    this.onHolesResultChanged,
    this.onStartHoleHunt,
  });

  @override
  State<PositionAnalysisWidget> createState() => _PositionAnalysisWidgetState();
}

class _PositionAnalysisWidgetState extends State<PositionAnalysisWidget>
    with SingleTickerProviderStateMixin {
  // ── Canonical position state ───────────────────────────────────────
  //
  // Every position change flows through [_navigateTo], which updates
  // all four of these in a single setState call.

  String? _currentFen;
  Position? _currentBoard;
  List<GameInfo> _currentGames = [];
  GameInfo? _selectedGame;

  late TabController _tabController;
  final PgnViewerWidgetController _pgnController = PgnViewerWidgetController();
  int _lastNavigateGeneration = 0;

  // ── Scratch analysis tree (Analysis tab) ───────────────────────────
  //
  // User workspace: off-book board moves, engine lines and manual
  // exploration accumulate here.  Persists across position selections;
  // cleared only by the user.

  MoveTree _scratchTree = MoveTree();
  TreePath _scratchCursor = TreePath.empty;

  static const int _kAnalysisTabIndex = 3;

  /// Starting-position board, shown when no FEN has been selected yet.
  static const Position _startingPosition = Chess.initial;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _tabController.addListener(_onTabChanged);
  }

  @override
  void didUpdateWidget(PositionAnalysisWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Tree swapped (colour switch or new player): each tree remembers its own
    // cursor, so sync the board/games to wherever the incoming tree left off.
    if (!identical(widget.openingTree, oldWidget.openingTree)) {
      final tree = widget.openingTree;
      if (tree != null) {
        _navigateTo(tree.currentNode.fen);
      } else {
        setState(() {
          _currentFen = null;
          _currentBoard = null;
          _currentGames = [];
          _selectedGame = null;
        });
      }
    }
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
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  /// Entering the Analysis tab: seed the scratch tree with the line to the
  /// current position so the analysis starts with its opening context.
  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index != _kAnalysisTabIndex || _currentFen == null) {
      return;
    }
    final path = _ensureScratchPathForFen(_currentFen!);
    if (path != null) {
      setState(() => _scratchCursor = path);
    }
  }

  // =====================================================================
  // Build
  // =====================================================================

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 720) {
            return Column(
              children: [
                Expanded(flex: 4, child: _buildBoardPane()),
                Container(height: 1, color: Colors.grey[700]),
                Expanded(flex: 5, child: _buildStackedPanels()),
              ],
            );
          }

          if (constraints.maxWidth < 1100) {
            return Column(
              children: [
                Expanded(flex: 4, child: _buildBoardPane()),
                Container(height: 1, color: Colors.grey[700]),
                Expanded(
                  flex: 5,
                  child: Row(
                    children: [
                      Expanded(child: _buildLeftPanel()),
                      Container(width: 1, color: Colors.grey[700]),
                      Expanded(child: _buildRightPanel()),
                    ],
                  ),
                ),
              ],
            );
          }

          final leftWidth = math.min(320.0, constraints.maxWidth * 0.26);
          final rightWidth = math.min(380.0, constraints.maxWidth * 0.3);

          return Row(
            children: [
              SizedBox(width: leftWidth, child: _buildLeftPanel()),
              Container(width: 1, color: Colors.grey[700]),
              Expanded(child: _buildBoardPane()),
              Container(width: 1, color: Colors.grey[700]),
              SizedBox(width: rightWidth, child: _buildRightPanel()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBoardPane() {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: AspectRatio(
                aspectRatio: 1.0,
                child: ChessBoardWidget(
                  position: _currentBoard ?? _startingPosition,
                  flipped: widget.playerIsWhite != null
                      ? !widget.playerIsWhite!
                      : false,
                  onMove: _onBoardMove,
                ),
              ),
            ),
          ),
        ),
        if (widget.analysis != null) _buildActionBar(),
      ],
    );
  }

  /// Handoff actions for the current position, pinned under the board.
  Widget _buildActionBar() {
    final hasFen = _currentFen != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 4,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.menu_book_outlined, size: 16),
            label: const Text('Add Line to Study',
                style: TextStyle(fontSize: 12)),
            onPressed: hasFen ? _addCurrentLineToStudy : null,
          ),
          TextButton.icon(
            icon: const Icon(Icons.extension_outlined, size: 16),
            label: const Text('Make Puzzle', style: TextStyle(fontSize: 12)),
            onPressed: hasFen ? _makePuzzleFromPosition : null,
          ),
          TextButton.icon(
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open Games in PGN Viewer',
                style: TextStyle(fontSize: 12)),
            onPressed:
                widget.analysisPgnPath != null ? _openGamesInPgnViewer : null,
          ),
        ],
      ),
    );
  }

  Widget _buildStackedPanels() {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Positions'),
              Tab(text: 'Details'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildLeftPanel(),
                _buildRightPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // =====================================================================
  // Keyboard navigation
  // =====================================================================

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (isTextInputFocused()) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.keyE && hasNoLetterModifiers) {
      InlineEngineBar.toggleEngine();
      return KeyEventResult.handled;
    }

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

    // Analysis tab: arrow keys move the scratch cursor.
    if (_tabController.index == _kAnalysisTabIndex) {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        if (_scratchCursor.isNotEmpty) _jumpScratch(_scratchCursor.parent);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        final children = _scratchCursor.isEmpty
            ? _scratchTree.roots
            : (_scratchTree.nodeAt(_scratchCursor)?.children ?? const []);
        if (children.isNotEmpty) _jumpScratch(_scratchCursor.child(0));
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
        openingTree: widget.openingTree,
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
  // Right panel (engine bar + tabs)
  // =====================================================================

  Widget _buildRightPanel() {
    return Column(
      children: [
        // One shared engine bar tracks the current position across all tabs
        // (the PGN tab feeds it through _onPgnPositionChanged).  Stored FENs
        // may be 4-field normalised, so expand before handing to the engine.
        InlineEngineBar(
          fen: _currentFen != null
              ? expandFen(_currentFen!)
              : _startingPosition.fen,
          onLineMoveTapped: _onEngineLineTapped,
        ),
        const Divider(height: 1),
        TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: [
            const Tab(text: 'Move Tree'),
            const Tab(text: 'Games'),
            const Tab(text: 'PGN'),
            const Tab(text: 'Analysis'),
            Tab(text: 'Holes${_holesCountLabel()}'),
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
              _buildScratchTab(),
              _buildHolesTab(),
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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
            onPathPlySelected: _onTreePathPlySelected,
            gamesAtPosition: _currentGames,
            onViewGamePgn: _onGameSelected,
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

    // The shared engine bar above the tabs covers this view too, so the
    // plain viewer is used rather than PgnWithEngine.
    return PgnViewerWidget(
      pgnText: _selectedGame!.pgnText!,
      controller: _pgnController,
      initialFen: _currentFen,
      onPositionChanged: (game) => _onPgnPositionChanged(game.fen),
    );
  }

  // =====================================================================
  // Holes tab (hole-hunt report)
  // =====================================================================

  /// " (n)" suffix for the Holes tab label, or empty when nothing to count.
  String _holesCountLabel() {
    final count = (widget.holesResult?.activeFindingCount ?? 0) +
        widget.holesLiveFindings.length;
    return count > 0 ? ' ($count)' : '';
  }

  Widget _buildHolesTab() {
    return HolesReportPanel(
      result: widget.holesResult,
      liveFindings: widget.holesLiveFindings,
      isHunting: widget.isHoleHunting,
      progress: widget.holesProgress,
      trapPassSkipped: widget.holesTrapPassSkipped,
      onFindingSelected: _onHoleFindingSelected,
      onResultChanged: widget.onHolesResultChanged,
      onStartHunt: widget.onStartHoleHunt,
    );
  }

  /// Clicking a finding jumps the board (and tree cursor) to its position.
  void _onHoleFindingSelected(AuditFinding finding) {
    widget.openingTree?.navigateToFen(finding.fen);
    _navigateTo(finding.fen);
  }

  // =====================================================================
  // Analysis tab (scratch tree)
  // =====================================================================

  Widget _buildScratchTab() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.menu_book_outlined, size: 16),
                label: const Text('Save Analysis to Study',
                    style: TextStyle(fontSize: 12)),
                onPressed: _scratchTree.isEmpty ? null : _addScratchToStudy,
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                tooltip: 'Clear Analysis',
                visualDensity: VisualDensity.compact,
                onPressed: _scratchTree.isEmpty ? null : _confirmClearScratch,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _scratchTree.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Your analysis workspace.\n\n'
                      'Play moves on the board (moves outside the '
                      'player\'s games land here) or click an engine '
                      'line to build variations, then save them to a study.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(4),
                  child: InteractivePgnEditor(
                    tree: _scratchTree,
                    currentPath: _scratchCursor,
                    onJump: _jumpScratch,
                    onCommentChanged: (path, comment) =>
                        setState(() => _scratchTree.setComment(path, comment)),
                    onDelete: _deleteScratchAt,
                    onPromote: _promoteScratchAt,
                    onMakeMainLine: _makeScratchMainLine,
                    onCopyToClipboard: (text, message) async {
                      await Clipboard.setData(ClipboardData(text: text));
                      if (mounted) showAppSnackBar(context, message);
                    },
                  ),
                ),
        ),
      ],
    );
  }

  /// Jump the scratch cursor and sync the board (and, best-effort, the
  /// opening tree) to that position.
  void _jumpScratch(TreePath path) {
    setState(() => _scratchCursor = path);
    final fen = _scratchTree.fenAt(path);
    widget.openingTree?.navigateToFen(fen);
    _navigateTo(fen);
  }

  void _deleteScratchAt(TreePath path) {
    setState(() {
      // Deleting a sibling shifts variation indices, so re-locate the cursor
      // by SAN afterwards; if the cursor's line was itself deleted, this
      // lands on its deepest surviving ancestor.
      final sanLine = _scratchTree.sanSequenceAt(_scratchCursor);
      _scratchTree.deleteAt(path);
      _reanchorScratchCursor(sanLine);
    });
  }

  void _promoteScratchAt(TreePath path) {
    final sanLine = _scratchTree.sanSequenceAt(_scratchCursor);
    setState(() {
      _scratchTree.promoteVariation(path);
      _reanchorScratchCursor(sanLine);
    });
  }

  /// Recursively promote so [target] lies on the mainline (same algorithm as
  /// StudyController.makeMainLine).
  void _makeScratchMainLine(TreePath target) {
    if (target.isEmpty) return;
    final sanLine = _scratchTree.sanSequenceAt(_scratchCursor);
    setState(() {
      final indices = target.toList();
      for (int depth = 0; depth < indices.length; depth++) {
        if (indices[depth] != 0) {
          _scratchTree.promoteVariation(TreePath(indices.sublist(0, depth + 1)));
          indices[depth] = 0;
        }
      }
      _reanchorScratchCursor(sanLine);
    });
  }

  /// After a structural change, re-locate the cursor by replaying its SAN
  /// sequence (paths shift when siblings reorder).
  void _reanchorScratchCursor(List<String> sanLine) {
    var path = TreePath.empty;
    var siblings = _scratchTree.roots;
    for (final san in sanLine) {
      final idx = siblings.indexWhere((n) => n.san == san);
      if (idx == -1) break;
      path = path.child(idx);
      siblings = siblings[idx].children;
    }
    _scratchCursor = path;
  }

  void _confirmClearScratch() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Analysis'),
        content: const Text(
            'Discard all moves in the Analysis tab? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              setState(() {
                _scratchTree = MoveTree();
                _scratchCursor = TreePath.empty;
              });
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  // ── Scratch tree bookkeeping ────────────────────────────────────────

  /// Path of a scratch node matching [fen], preferring the cursor when it
  /// already sits on that position (avoids jumping to a transposition).
  TreePath? _scratchAnchorFor(String fen) {
    final target = normalizeFen(fen);
    if (normalizeFen(_scratchTree.fenAt(_scratchCursor)) == target) {
      return _scratchCursor;
    }
    if (normalizeFen(_scratchTree.startingFen) == target) {
      return TreePath.empty;
    }
    TreePath? found;
    void walk(List<MoveNode> siblings, TreePath parent) {
      for (var i = 0; i < siblings.length && found == null; i++) {
        final path = parent.child(i);
        if (normalizeFen(siblings[i].fen) == target) {
          found = path;
          return;
        }
        walk(siblings[i].children, path);
      }
    }

    walk(_scratchTree.roots, TreePath.empty);
    return found;
  }

  /// SAN path from the game start to [fen], derived from the opening tree.
  List<String>? _openingTreePathFor(String fen) {
    final tree = widget.openingTree;
    if (tree == null) return null;
    final target = normalizeFen(fen);
    if (normalizeFen(tree.currentNode.fen) == target) {
      return tree.currentNode.getMovePath();
    }
    if (normalizeFen(tree.root.fen) == target) return const [];
    final nodes = tree.fenToNodes[target];
    if (nodes != null && nodes.isNotEmpty) return nodes.first.getMovePath();
    return null;
  }

  /// Ensure [fen] is reachable in the scratch tree and return its path:
  /// reuses an existing node, else seeds the book line leading to the
  /// position (tagging the leaf with the player's stats), else — for an
  /// empty tree — re-roots at the position itself.  Returns null when the
  /// position can't be attached without discarding existing analysis.
  TreePath? _ensureScratchPathForFen(String fen) {
    final anchor = _scratchAnchorFor(fen);
    if (anchor != null) return anchor;

    final sans = _openingTreePathFor(fen);
    if (sans != null) {
      final startFen = widget.openingTree!.root.fen;
      if (_scratchTree.isEmpty &&
          normalizeFen(_scratchTree.startingFen) != normalizeFen(startFen)) {
        _scratchTree = MoveTree(startingFen: startFen);
      }
      // Only replay the book SANs when the roots actually match — grafting a
      // from-the-start line onto a re-rooted (mid-game) tree could splice in
      // moves that happen to be legal but mean something entirely different.
      var ok =
          normalizeFen(_scratchTree.startingFen) == normalizeFen(startFen);
      var path = TreePath.empty;
      if (ok) {
        for (final san in sans) {
          final next = _scratchTree.addMove(path, san);
          if (next == null) {
            ok = false;
            break;
          }
          path = next;
        }
      }
      if (ok) {
        final node = path.isEmpty ? null : _scratchTree.nodeAt(path);
        final comment = _statsCommentFor(fen);
        if (node != null &&
            comment != null &&
            (node.comment == null || node.comment!.isEmpty)) {
          node.comment = comment;
        }
        return path;
      }
    }

    if (_scratchTree.isEmpty) {
      _scratchTree = MoveTree(startingFen: expandFen(fen));
      return TreePath.empty;
    }
    return null;
  }

  /// Record a board move into the scratch tree (creates the book prefix on
  /// demand).  No-op when the pre-move position can't be attached.
  void _recordScratchMove(String preFen, String san) {
    final parent = _ensureScratchPathForFen(preFen);
    if (parent == null) return;
    final path = _scratchTree.addMove(parent, san);
    if (path == null) return;
    setState(() => _scratchCursor = path);
  }

  /// Engine bar: clicking a PV move plays the line into the Analysis tab.
  void _onEngineLineTapped(List<String> sanMoves, int clickedIndex) {
    final fen = _currentFen ?? _startingPosition.fen;
    final seeded = _ensureScratchPathForFen(fen);
    if (seeded == null) {
      showAppSnackBar(
        context,
        'Could not add the engine line: the position is not in the '
        'Analysis tab.',
      );
      return;
    }
    TreePath path = seeded;
    for (var i = 0; i <= clickedIndex && i < sanMoves.length; i++) {
      final next = _scratchTree.addMove(path, sanMoves[i]);
      if (next == null) break;
      path = next;
    }
    setState(() => _scratchCursor = path);
    final newFen = _scratchTree.fenAt(path);
    widget.openingTree?.navigateToFen(newFen);
    _navigateTo(newFen);
    _tabController.animateTo(_kAnalysisTabIndex);
  }

  // =====================================================================
  // Handoffs: study / puzzle / PGN viewer
  // =====================================================================

  /// Player stats at [fen] as a human-readable PGN comment, or null.
  String? _statsCommentFor(String fen) {
    final stats = widget.analysis?.positionStats[normalizeFen(fen)];
    if (stats == null || stats.games == 0) return null;
    final who = widget.playerName ?? 'Player';
    return '$who scored ${stats.winRatePercent.toStringAsFixed(1)}% here '
        '(${stats.wins}-${stats.losses}-${stats.draws} '
        'in ${stats.games} game${stats.games == 1 ? '' : 's'}).';
  }

  String _suggestChapterName(String? fen) {
    final who = widget.playerName ?? 'Analysis';
    final color = widget.playerIsWhite == null
        ? ''
        : (widget.playerIsWhite! ? ' as White' : ' as Black');
    final stats =
        fen == null ? null : widget.analysis?.positionStats[normalizeFen(fen)];
    final statsPart = (stats != null && stats.games > 0)
        ? ' — ${stats.winRatePercent.toStringAsFixed(0)}% in '
            '${stats.games} game${stats.games == 1 ? '' : 's'}'
        : '';
    return '$who$color$statsPart';
  }

  /// Single line (root → cursor-line leaf) through [path], comments intact.
  MoveTree _scratchLineTree(TreePath path) {
    final end = _scratchTree.mainlineEndFrom(path);
    final chain = _scratchTree.nodeListAt(end);
    final clone = MoveTree(startingFen: _scratchTree.startingFen);
    var siblings = clone.roots;
    for (final n in chain) {
      final copy = MoveNode(
        san: n.san,
        fen: n.fen,
        comment: n.comment,
        nags: n.nags == null ? null : List.of(n.nags!),
      );
      siblings.add(copy);
      siblings = copy.children;
    }
    return clone;
  }

  /// The line of the player's games leading to [fen], with a stats comment
  /// on the final move.  Null when the position isn't in the opening tree.
  MoveTree? _bookLineTree(String fen) {
    final sans = _openingTreePathFor(fen);
    if (sans == null) return null;
    final tree = MoveTree(startingFen: widget.openingTree!.root.fen);
    var path = TreePath.empty;
    for (final san in sans) {
      final next = tree.addMove(path, san);
      if (next == null) return null;
      path = next;
    }
    final comment = _statsCommentFor(fen);
    if (comment != null && path.isNotEmpty) tree.setComment(path, comment);
    return tree;
  }

  /// "Add Line to Study" (board action bar): saves the line to the current
  /// position — from the Analysis workspace when the position lives there
  /// (keeps the user's own moves and comments), else from the game tree.
  Future<void> _addCurrentLineToStudy() async {
    final fen = _currentFen;
    if (fen == null) return;

    MoveTree? line;
    final anchor = _scratchAnchorFor(fen);
    if (anchor != null && _scratchTree.isNotEmpty) {
      line = _scratchLineTree(anchor);
    }
    if (line == null || line.isEmpty) {
      line = _bookLineTree(fen);
    }
    if (line == null || line.isEmpty) {
      showAppSnackBar(
        context,
        'Could not build a line to this position from the games.',
      );
      return;
    }
    await _saveTreeToStudy(line, _suggestChapterName(fen));
  }

  /// "Save Analysis to Study" (Analysis tab): saves the whole scratch tree —
  /// all variations and comments — as one chapter.
  Future<void> _addScratchToStudy() async {
    if (_scratchTree.isEmpty) return;
    await _saveTreeToStudy(_scratchTree, _suggestChapterName(_currentFen));
  }

  Future<void> _saveTreeToStudy(
      MoveTree lineTree, String suggestedChapter) async {
    final result = await showDialog<AddToStudyResult>(
      context: context,
      builder: (_) => AddToStudyDialog(initialChapterName: suggestedChapter),
    );
    if (result == null || !mounted) return;

    final study = context.read<StudyController>();
    final appState = context.read<AppState>();
    try {
      final path = result.existingPath ??
          await StorageFactory.instance.studyFilePath(result.newStudyName!);
      final pgn = lineTree.toPgn(event: result.chapterName, result: '*');
      await study.addChapterToStudyFile(path, result.chapterName, pgn);
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Added "${result.chapterName}" to ${result.studyName}',
        actionLabel: 'Open',
        onAction: () async {
          await study.openStudy(path);
          study.selectChapter(study.doc.chapters.length - 1);
          appState.setMode(AppMode.study);
        },
      );
    } catch (e) {
      debugPrint('Add line to study failed: $e');
      if (mounted) {
        showAppSnackBar(context, 'Failed to add line to study.',
            isError: true);
      }
    }
  }

  void _makePuzzleFromPosition() {
    final fen = _currentFen;
    if (fen == null) return;
    context.read<AppState>().switchToPuzzleCreator(seedFen: expandFen(fen));
  }

  void _openGamesInPgnViewer() {
    final path = widget.analysisPgnPath;
    if (path == null) return;
    final fen = _currentFen;
    context.read<AppState>().switchToPgnViewer(
          path: path,
          sliceFen: fen == null ? null : normalizeFen(fen),
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

  // =====================================================================
  // Helpers
  // =====================================================================

  /// Parse a (possibly 4-field) FEN into a [Position] instance.
  static Position? _parseFen(String fen) {
    try {
      return Chess.fromSetup(Setup.parseFen(expandFen(fen)));
    } catch (_) {
      return null;
    }
  }
}
