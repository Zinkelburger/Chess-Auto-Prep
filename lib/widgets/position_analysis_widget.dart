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

part 'position_analysis_widget.scratch.dart';
part 'position_analysis_widget.handoffs.dart';
part 'position_analysis_widget.navigation.dart';

const int _kAnalysisTabIndex = 3;

/// Starting-position board, shown when no FEN has been selected yet.
const Position _startingPosition = Chess.initial;

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

/// Shared state for [PositionAnalysisWidget], carried by the concrete State
/// and the part-file mixins ([_ScratchAnalysisMixin], [_StudyHandoffMixin],
/// [_NavigationMixin]) that operate on it.
abstract class _PositionAnalysisWidgetStateBase
    extends State<PositionAnalysisWidget> {
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

  // ── Cross-mixin forward declarations ────────────────────────────────
  //
  // Provided by the concrete State / part-file mixins below; declared here
  // so each mixin (which sees only this base) can call across groups.

  void _navigateTo(String fen);
  String? _statsCommentFor(String fen);
  TreePath? _scratchAnchorFor(String fen);
  List<String>? _openingTreePathFor(String fen);
  void _recordScratchMove(String preFen, String san);
  Future<void> _addScratchToStudy();
}

class _PositionAnalysisWidgetState extends _PositionAnalysisWidgetStateBase
    with
        SingleTickerProviderStateMixin,
        _ScratchAnalysisMixin,
        _StudyHandoffMixin,
        _NavigationMixin {
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
            label: const Text(
              'Add Line to Study',
              style: TextStyle(fontSize: 12),
            ),
            onPressed: hasFen ? _addCurrentLineToStudy : null,
          ),
          TextButton.icon(
            icon: const Icon(Icons.extension_outlined, size: 16),
            label: const Text('Make Puzzle', style: TextStyle(fontSize: 12)),
            onPressed: hasFen ? _makePuzzleFromPosition : null,
          ),
          TextButton.icon(
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text(
              'Open Games in PGN Viewer',
              style: TextStyle(fontSize: 12),
            ),
            onPressed: widget.analysisPgnPath != null
                ? _openGamesInPgnViewer
                : null,
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
              children: [_buildLeftPanel(), _buildRightPanel()],
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
            Text('Analyzing positions…', style: TextStyle(color: Colors.grey)),
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
    final count =
        (widget.holesResult?.activeFindingCount ?? 0) +
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
}

// =====================================================================
// Helpers
// =====================================================================

/// Parse a (possibly 4-field) FEN into a [Position] instance.
Position? _parseFen(String fen) {
  try {
    return Chess.fromSetup(Setup.parseFen(expandFen(fen)));
  } catch (_) {
    return null;
  }
}
