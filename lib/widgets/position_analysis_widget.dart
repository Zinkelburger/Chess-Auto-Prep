/// Position analysis widget – three-panel layout for the Player Analysis screen.
///
/// Left: the ranked lists that drive the board — Positions · Holes · Tricks,
/// chosen with a selector that always shows each report's finding count.
/// Centre: chess board. Right: engine bar + a tabbed pane of views onto the
/// *current* position (Move Tree · Games · PGN · Analysis), four tabs so none
/// of them can be pushed off a scrolling tab bar.
///
/// The study / puzzle / PGN-viewer handoffs are exposed to the host screen's
/// app bar through [PositionAnalysisActions].
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
import '../features/audit/models/audit_finding.dart';
import '../features/audit/models/audit_result.dart';
import '../features/audit/services/audit_board_annotations.dart';
import '../features/holes/services/hole_hunt_service.dart';
import '../features/holes/widgets/holes_report_panel.dart';
import '../features/tricks/services/trick_hunt_service.dart';
import '../features/tricks/widgets/tricks_report_panel.dart';
import '../models/move_tree.dart';
import '../models/position_analysis.dart';
import '../models/opening_tree.dart';
import '../theme/app_colors.dart';
import '../utils/app_messages.dart';
import '../utils/fen_utils.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/fen_list_widget.dart';
import '../widgets/games_list_widget.dart';
import '../widgets/opening_tree_widget.dart';
import 'chess_board_widget.dart';
import 'common/list_nav.dart';
import 'engine/inline_engine_bar.dart';
import 'interactive_pgn_editor.dart';
import 'study/add_to_study_flow.dart';
import 'pgn_viewer_widget.dart';

part 'position_analysis_widget.scratch.dart';
part 'position_analysis_widget.handoffs.dart';
part 'position_analysis_widget.navigation.dart';

const int _kAnalysisTabIndex = 3;

/// What the left column is listing. All three are "pick an item, the board
/// jumps there" lists, which is why they share one column instead of being
/// squeezed into the right pane's tab bar alongside views of the *current*
/// position.
enum _LeftPanelMode { positions, holes, tricks }

/// Starting-position board, shown when no FEN has been selected yet.
const Position _startingPosition = Chess.initial;

/// Exposes the board handoff actions (add line to study, open games in the
/// PGN viewer) to the host screen, which surfaces them in its app bar
/// instead of buttons under the board. Lines are the one save primitive: a
/// puzzle is a segment of a study line marked "Puzzle starts here" in Study,
/// not a separate artifact authored from this screen.
class PositionAnalysisActions {
  _PositionAnalysisWidgetState? _state;

  void _attach(_PositionAnalysisWidgetState state) => _state = state;

  void _detach(_PositionAnalysisWidgetState state) {
    if (_state == state) _state = null;
  }

  bool get hasPosition => _state?._currentFen != null;
  bool get canOpenGames => _state?.widget.analysisPgnPath != null;

  Future<void> addCurrentLineToStudy() async =>
      _state?._addCurrentLineToStudy();

  void openGamesInPgnViewer() => _state?._openGamesInPgnViewer();
}

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

  // ── Trick hunt (Tricks tab) — state owned by the host screen ────────

  /// Completed trick-hunt report for the displayed colour, if any.
  final AuditResult? tricksResult;

  /// Findings streamed from an in-flight trick hunt on the displayed colour.
  final List<AuditFinding> tricksLiveFindings;

  /// True while a trick hunt is running on the displayed colour's tree.
  final bool isTrickHunting;
  final TrickHuntProgress? tricksProgress;

  /// Show the "probes skipped" note (Maia unavailable).
  final bool tricksProbesSkipped;

  /// Re-persist after dismissal edits in the report panel.
  final void Function(AuditResult result)? onTricksResultChanged;

  /// Open the trick-hunt config to start (or re-run) a hunt.
  final VoidCallback? onStartTrickHunt;

  /// Handle for the host screen's app-bar menu to trigger the handoff
  /// actions (study / puzzle / PGN viewer).
  final PositionAnalysisActions? actions;

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
    this.tricksResult,
    this.tricksLiveFindings = const [],
    this.isTrickHunting = false,
    this.tricksProgress,
    this.tricksProbesSkipped = false,
    this.onTricksResultChanged,
    this.onStartTrickHunt,
    this.actions,
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

  // One nav controller per left-column list; ↓/↑ go to whichever is showing.
  final ListNavController _positionsNav = ListNavController();
  final ListNavController _holesNav = ListNavController();
  final ListNavController _tricksNav = ListNavController();

  /// Which list the left column shows. Never hidden behind a menu: the
  /// selector carries the finding counts, so an unread report announces
  /// itself instead of sitting off the end of a scrolled tab bar.
  _LeftPanelMode _leftMode = _LeftPanelMode.positions;

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
    widget.actions?._attach(this);
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(_onTabChanged);
  }

  @override
  void didUpdateWidget(PositionAnalysisWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.actions, oldWidget.actions)) {
      oldWidget.actions?._detach(this);
      widget.actions?._attach(this);
    }
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
    // Starting a hunt is a request to watch it: swing the left column to the
    // report so findings stream into view instead of accumulating behind a
    // selector the user has to think to press.
    if (widget.isHoleHunting && !oldWidget.isHoleHunting) {
      _leftMode = _LeftPanelMode.holes;
    } else if (widget.isTrickHunting && !oldWidget.isTrickHunting) {
      _leftMode = _LeftPanelMode.tricks;
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
    widget.actions?._detach(this);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  /// Entering the Analysis tab: seed the scratch tree with the line to the
  /// current position so the analysis starts with its opening context.
  /// Every settled tab change rebuilds, so the arrow-key bindings (whose
  /// meaning depends on the active tab) are re-read.
  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == _kAnalysisTabIndex && _currentFen != null) {
      final path = _ensureScratchPathForFen(_currentFen!);
      if (path != null) _scratchCursor = path;
    }
    setState(() {});
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
                Container(height: 1, color: AppColors.outline),
                Expanded(flex: 5, child: _buildStackedPanels()),
              ],
            );
          }

          if (constraints.maxWidth < 1100) {
            return Column(
              children: [
                Expanded(flex: 4, child: _buildBoardPane()),
                Container(height: 1, color: AppColors.outline),
                Expanded(
                  flex: 5,
                  child: Row(
                    children: [
                      Expanded(child: _buildLeftPanel()),
                      Container(width: 1, color: AppColors.outline),
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
              Container(width: 1, color: AppColors.outline),
              Expanded(child: _buildBoardPane()),
              Container(width: 1, color: AppColors.outline),
              SizedBox(width: rightWidth, child: _buildRightPanel()),
            ],
          );
        },
      ),
    );
  }

  // The study / puzzle / PGN-viewer handoffs live in the host screen's
  // app-bar kebab menu (see [PositionAnalysisActions]) — the board keeps
  // the full pane to itself.
  Widget _buildBoardPane() {
    return Center(
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
            // Each list is gated on its own tab, so at most one contributes.
            annotations: [
              ..._holesBoardAnnotations(),
              ..._tricksBoardAnnotations(),
            ],
          ),
        ),
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
              Tab(text: 'Positions & Reports'),
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

  /// Shortcuts, dispatched through [handleKeyBindings] (never while typing).
  /// Left/right arrows navigate *moves* and follow the active right-pane
  /// tab; down/up step the left column's active list — two axes that never
  /// collide.
  List<KeyBinding> get _keyBindings => [
    KeyBinding.run(
      LogicalKeyboardKey.keyE,
      'Toggle engine',
      InlineEngineBar.toggleEngine,
    ),
    // The app-wide Escape contract: leave what you are in. Here the only thing
    // you can be "in" is a tab other than the first, so Escape backs out to it
    // — the same key doing the same thing as on the tactics panel.
    KeyBinding(LogicalKeyboardKey.escape, 'Back to the first tab', () {
      if (_tabController.index == 0) return false;
      _tabController.animateTo(0);
      return true;
    }),
    // ↓/↑ step whichever left-column list is showing (positions, holes or
    // tricks). Deliberately no letter aliases: N is the knight and most
    // other candidates are SAN characters too, so arrows are the app-wide
    // list-stepping keys.
    KeyBinding.run(
      LogicalKeyboardKey.arrowDown,
      'Next item in the left list',
      _activeListNav.selectNext,
      repeats: true,
    ),
    KeyBinding.run(
      LogicalKeyboardKey.arrowUp,
      'Previous item in the left list',
      _activeListNav.selectPrevious,
      repeats: true,
    ),
    // Move Tree tab: arrow keys navigate the tree.
    if (_tabController.index == 0 && widget.openingTree != null) ...[
      KeyBinding.run(
        LogicalKeyboardKey.arrowLeft,
        'Back one move',
        _treeGoBack,
      ),
      KeyBinding.run(
        LogicalKeyboardKey.arrowRight,
        'Forward one move',
        _treeGoForward,
      ),
    ],
    // PGN tab: arrow keys navigate the PGN.
    if (_tabController.index == 2) ...[
      KeyBinding.run(
        LogicalKeyboardKey.arrowLeft,
        'Back one move',
        _pgnController.goBack,
      ),
      KeyBinding.run(
        LogicalKeyboardKey.arrowRight,
        'Forward one move',
        _pgnController.goForward,
      ),
    ],
    // Analysis tab: arrow keys move the scratch cursor.
    if (_tabController.index == _kAnalysisTabIndex) ...[
      KeyBinding.run(LogicalKeyboardKey.arrowLeft, 'Back one move', () {
        if (_scratchCursor.isNotEmpty) _jumpScratch(_scratchCursor.parent);
      }),
      KeyBinding.run(LogicalKeyboardKey.arrowRight, 'Forward one move', () {
        final children = _scratchCursor.isEmpty
            ? _scratchTree.roots
            : (_scratchTree.nodeAt(_scratchCursor)?.children ?? const []);
        if (children.isNotEmpty) _jumpScratch(_scratchCursor.child(0));
      }),
    ],
  ];

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) =>
      handleKeyBindings(_keyBindings, event, node: node);

  /// The nav controller of the list the left column is showing. Stepping is
  /// a no-op when that list isn't mounted (nothing attached).
  ListNavController get _activeListNav => switch (_leftMode) {
    _LeftPanelMode.positions => _positionsNav,
    _LeftPanelMode.holes => _holesNav,
    _LeftPanelMode.tricks => _tricksNav,
  };

  // =====================================================================
  // Left panel
  // =====================================================================

  /// The left column: a mode selector over whichever list is active. The
  /// reports live here rather than in the right pane's tabs because they are
  /// the same *kind* of thing as the position list — a ranked list you work
  /// down, each row driving the board — whereas every right-pane tab is a
  /// view of the position you are already on.
  Widget _buildLeftPanel() {
    return Column(
      children: [
        _buildLeftModeSelector(),
        const Divider(height: 1),
        Expanded(
          child: switch (_leftMode) {
            _LeftPanelMode.positions => _buildPositionsList(),
            _LeftPanelMode.holes => _buildHolesReport(),
            _LeftPanelMode.tricks => _buildTricksReport(),
          },
        ),
      ],
    );
  }

  Widget _buildLeftModeSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<_LeftPanelMode>(
          segments: [
            const ButtonSegment(
              value: _LeftPanelMode.positions,
              label: Text('Positions'),
            ),
            ButtonSegment(
              value: _LeftPanelMode.holes,
              label: Text('Holes${_holesCountLabel()}'),
            ),
            ButtonSegment(
              value: _LeftPanelMode.tricks,
              label: Text('Tricks${_tricksCountLabel()}'),
            ),
          ],
          selected: {_leftMode},
          // The board's finding arrows are gated on the mode, so switching
          // has to repaint the board too.
          onSelectionChanged: (s) => setState(() => _leftMode = s.first),
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 6),
            ),
            textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11)),
          ),
        ),
      ),
    );
  }

  Widget _buildPositionsList() {
    if (widget.analysis != null) {
      return FenListWidget(
        analysis: widget.analysis!,
        onFenSelected: _onFenSelected,
        playerIsWhite: widget.playerIsWhite ?? true,
        hasEvals: widget.hasEvals,
        openingTree: widget.openingTree,
        navController: _positionsNav,
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
              style: TextStyle(color: AppColors.onSurfaceMuted),
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
          style: TextStyle(color: AppColors.onSurfaceMuted),
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
        // Four tabs, all of them views of the position you are on, so they
        // fit without scrolling — no label can be pushed off the edge.
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Move Tree'),
            Tab(text: 'Games'),
            Tab(text: 'PGN'),
            Tab(text: 'Analysis'),
          ],
          labelPadding: const EdgeInsets.symmetric(horizontal: 4),
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
          style: TextStyle(color: AppColors.onSurfaceMuted),
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
            protagonistIsWhite: widget.playerIsWhite,
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
          style: TextStyle(color: AppColors.onSurfaceMuted),
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
  // Holes report (left column)
  // =====================================================================

  /// " (n)" suffix for the Holes segment, or empty when nothing to count.
  String _holesCountLabel() {
    final count =
        (widget.holesResult?.activeFindingCount ?? 0) +
        widget.holesLiveFindings.length;
    return count > 0 ? ' ($count)' : '';
  }

  Widget _buildHolesReport() {
    return HolesReportPanel(
      result: widget.holesResult,
      liveFindings: widget.holesLiveFindings,
      isHunting: widget.isHoleHunting,
      progress: widget.holesProgress,
      trapPassSkipped: widget.holesTrapPassSkipped,
      onFindingSelected: _onHoleFindingSelected,
      onResultChanged: widget.onHolesResultChanged,
      onStartHunt: widget.onStartHoleHunt,
      navController: _holesNav,
    );
  }

  /// Clicking a finding jumps the board (and tree cursor) to its position.
  void _onHoleFindingSelected(AuditFinding finding) {
    widget.openingTree?.navigateToFen(finding.fen);
    _navigateTo(finding.fen);
  }

  /// Arrows for hole findings at the displayed position — built only while
  /// the Holes report is showing so they never bleed into normal browsing.
  List<BoardAnnotation> _holesBoardAnnotations() {
    if (_leftMode != _LeftPanelMode.holes || _currentFen == null) {
      return const [];
    }
    return buildAuditBoardAnnotations(
      result: widget.holesResult,
      currentFen: expandFen(_currentFen!),
    );
  }

  // =====================================================================
  // Tricks report (left column)
  // =====================================================================

  /// " (n)" suffix for the Tricks segment, or empty when nothing to count.
  String _tricksCountLabel() {
    final count =
        (widget.tricksResult?.activeFindingCount ?? 0) +
        widget.tricksLiveFindings.length;
    return count > 0 ? ' ($count)' : '';
  }

  Widget _buildTricksReport() {
    return TricksReportPanel(
      result: widget.tricksResult,
      liveFindings: widget.tricksLiveFindings,
      isHunting: widget.isTrickHunting,
      progress: widget.tricksProgress,
      probesSkipped: widget.tricksProbesSkipped,
      onFindingSelected: _onTrickFindingSelected,
      onResultChanged: widget.onTricksResultChanged,
      onStartHunt: widget.onStartTrickHunt,
      navController: _tricksNav,
    );
  }

  /// Clicking a finding jumps the board (and tree cursor) to its position.
  void _onTrickFindingSelected(AuditFinding finding) {
    widget.openingTree?.navigateToFen(finding.fen);
    _navigateTo(finding.fen);
  }

  /// Arrows for trick findings at the displayed position — built only while
  /// the Tricks report is showing so they never bleed into normal browsing.
  List<BoardAnnotation> _tricksBoardAnnotations() {
    if (_leftMode != _LeftPanelMode.tricks || _currentFen == null) {
      return const [];
    }
    return buildAuditBoardAnnotations(
      result: widget.tricksResult,
      currentFen: expandFen(_currentFen!),
    );
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
