import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartchess/dartchess.dart';
import 'package:provider/provider.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/core/study_controller.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/utils/app_messages.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:chess_auto_prep/utils/pgn_date_utils.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart'
    show coordsAtPly, plyBeforeMove;
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/theme/app_text_styles.dart';
import 'package:chess_auto_prep/theme/pgn_text_styles.dart';
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart'
    show toggleQualityNag;
import 'package:chess_auto_prep/widgets/pgn/add_to_study_dialog.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_movetext_view.dart';
import 'package:chess_auto_prep/core/pgn/pgn_variation_extractor.dart';
import 'package:chess_auto_prep/core/pgn/pgn_viewer_handle.dart';

part 'pgn/pgn_viewer_widget_navigation.dart';
part 'pgn/pgn_viewer_widget_move_edits.dart';
part 'pgn/pgn_viewer_widget_annotations.dart';
part 'pgn/pgn_viewer_widget_line_actions.dart';

class PgnViewerWidgetController implements PgnViewerHandle {
  _PgnViewerWidgetState? _state;

  void _attach(_PgnViewerWidgetState state) {
    _state = state;
  }

  void _detach(_PgnViewerWidgetState state) {
    if (_state == state) {
      _state = null;
    }
  }

  @override
  void goBack() {
    _state?._goBack();
  }

  @override
  void goForward() {
    _state?._goForward();
  }

  @override
  void addEphemeralMove(String san) {
    _state?._addAnalysisMove(san);
  }

  @override
  String? get currentFen => _state?._currentPosition.fen;

  @override
  void clearEphemeralMoves() {
    _state?._clearAnalysis();
  }

  @override
  void jumpToMove(int moveNumber, bool isWhiteToPlay) {
    final state = _state;
    if (state == null) return;
    state._clearAnalysis();
    state._jumpToMove(moveNumber, isWhiteToPlay);
  }

  /// Navigate directly to a mainline position by half-move index (0-based
  /// number of moves played from the start).
  @override
  void goToMainLineIndex(int moveIndex) {
    _state?._goToMainLineMove(moveIndex);
  }

  void deleteAnalysisNode(int nodeId) {
    _state?._deleteAnalysisNode(nodeId);
  }

  bool get hasAnalysis {
    final state = _state;
    if (state == null) return false;
    return state._variationsByPly.values.any((list) => list.isNotEmpty);
  }

  /// True when the user has added ephemeral analysis lines (not from PGN).
  bool get hasEphemeralMoves {
    final state = _state;
    if (state == null) return false;
    for (final roots in state._variationsByPly.values) {
      for (final root in roots) {
        if (state._subtreeHasEphemeral(root)) return true;
      }
    }
    return false;
  }

  @override
  int get mainLineIndex => _state?._mainLineIndex ?? 0;

  int get currentMainLineIndex => mainLineIndex;

  @override
  int get mainLineLength => _state?._moveHistory.length ?? 0;

  /// Mainline move SANs in order (for solitaire mode validation).
  @override
  List<String> get mainLineMoves =>
      _state?._moveHistory.map((m) => m.san).toList() ?? const [];

  /// Number of moves deep into the current variation (0 if on mainline).
  int get variationDepth => _state?._analysisPath.length ?? 0;

  /// True when navigation is inside a variation / inline preview (off mainline).
  @override
  bool get inVariation => _state?._isInVariation ?? false;

  /// Jump from the current variation back to the mainline branch point.
  void returnToMainline() => _state?._returnToMainline();

  /// Number of continuation candidates at the current fork (< 2 when linear).
  int get branchCandidateCount => _state?._branchCandidates().length ?? 0;

  /// Play the [index]-th (0-based) branch candidate shown in the fork bar.
  /// Returns false when there is no fork or the index is out of range.
  bool selectBranchCandidate(int index) {
    final state = _state;
    if (state == null) return false;
    final candidates = state._branchCandidates();
    if (candidates.length < 2 || index < 0 || index >= candidates.length) {
      return false;
    }
    candidates[index].onTap();
    return true;
  }

  /// Toggle a NAG on a specific move (used by keyboard shortcuts).
  void toggleNagOnMove(int moveIndex, int nagId) {
    _state?._toggleNag(moveIndex, nagId);
  }

  /// Record [san] as an ephemeral variation at the current mainline position
  /// without navigating into it (solitaire wrong attempts, shown live).
  @override
  void recordVariationMove(String san) => _state?._recordVariationMove(san);

  /// Append solitaire guess notes to mainline move comments ([notes] keyed by
  /// 0-based move index) and persist through the standard movetext serializer,
  /// keeping the game's own annotations intact.
  @override
  void addGuessAnnotations(Map<int, String> notes) =>
      _state?._addGuessAnnotations(notes);
}

class PgnViewerWidget extends StatefulWidget {
  final String? gameId;
  final String? pgnText;
  final int? moveNumber;
  final bool? isWhiteToPlay;
  final Function(Position)? onPositionChanged;
  final PgnViewerWidgetController? controller;
  final String? initialFen;
  final bool showStartEndButtons;
  final ValueChanged<String>? onCommentsChanged;
  final bool editMode;

  /// When non-null, movetext hides moves at index >= this value.
  final int? revealedPly;

  /// Opt-in book-PGN comment formatting (Chessable rich blocks, double-space
  /// paragraph breaks). Off by default — see [PgnMovetextView.bookFormatting].
  final bool bookFormatting;

  const PgnViewerWidget({
    super.key,
    this.gameId,
    this.pgnText,
    this.moveNumber,
    this.isWhiteToPlay,
    this.onPositionChanged,
    this.controller,
    this.initialFen,
    this.showStartEndButtons = true,
    this.onCommentsChanged,
    this.editMode = false,
    this.revealedPly,
    this.bookFormatting = false,
  });

  @override
  State<PgnViewerWidget> createState() => _PgnViewerWidgetState();
}

final _headerLineRe = RegExp(r'^\s*\[.*\]\s*$', multiLine: true);

String _stripHeaders(String pgn) => pgn.replaceAll(_headerLineRe, '').trim();

bool _isBlankHeader(String value) {
  final v = value.trim();
  return v.isEmpty || v == '?' || RegExp(r'^[?. *]+$').hasMatch(v);
}

/// Shared state for [_PgnViewerWidgetState] and the private part-file mixins
/// (navigation, move edits, annotations, line actions) that operate on it.
/// Members defined by one mixin but called from another are declared abstract
/// here so every mixin can reach them through its `on` constraint.
abstract class _PgnViewerWidgetStateBase extends State<PgnViewerWidget> {
  PgnGame? _game;
  List<PgnNodeData> _moveHistory = [];
  int _mainLineIndex = 0;
  Position _currentPosition = Chess.initial;
  Position _startPosition = Chess.initial;

  // Variations: ply (0-based mainline index) -> list of root MoveNodes.
  // Supports multiple branch points simultaneously.
  Map<int, List<MoveNode>> _variationsByPly = {};
  int _activeBranchPly = -1; // which ply we're currently navigating in
  List<MoveNode> _analysisPath = [];

  // Inline-comment line preview: steps the board through a clickable analysis
  // line embedded in a comment WITHOUT injecting it into the move tree, so the
  // comment keeps its pretty inline rendering. Fully decoupled from
  // _analysisPath / ephemeral nodes.
  List<String> _inlineSans = const [];
  int _inlineBaseIndex = 0; // mainline ply before the line's first move
  String? _inlineAnchorFen; // FEN the line starts from, when comment-anchored
  int _inlineCursor = 0; // # of inline moves currently played (>=1 = active)
  int _inlineFirstMoveNumber = 0; // run's first move, for highlight matching
  bool _inlineFirstIsWhite = true;

  bool get _inlineActive => _inlineCursor > 0 && _inlineSans.isNotEmpty;

  // Cross-group members: each is implemented in the named part-file mixin.
  void _clearAnalysis(); // move edits
  void _deleteAnalysisNode(int nodeId); // move edits
  void _clearInlineLine(); // navigation
  void _goToAnalysisNode(MoveNode targetNode, int branchPly); // navigation
  List<MoveNode>? _findPathToNode(
    MoveNode target,
    List<MoveNode> roots,
  ); // navigation
  void _promoteNodeLineage(MoveNode node); // annotations
  void _startEditingComment(int moveIndex); // annotations
  void _notifyCommentsChanged(); // line actions
}

class _PgnViewerWidgetState extends _PgnViewerWidgetStateBase
    with
        AutomaticKeepAliveClientMixin,
        _PgnViewerNavigation,
        _PgnViewerMoveEdits,
        _PgnViewerAnnotations,
        _PgnViewerLineActions {
  String _gameInfo = '';
  bool _isLoading = true;
  String? _error;

  // Auto-scroll the movetext so the current move stays visible as the user
  // navigates with the arrow keys.
  final ScrollController _movetextScrollController = ScrollController();
  final GlobalKey _currentMoveKey = GlobalKey();
  int _lastScrolledIndex = -1;

  void _scheduleScrollCurrentMoveIntoView() {
    if (_mainLineIndex == _lastScrolledIndex) return;
    _lastScrolledIndex = _mainLineIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _currentMoveKey.currentContext;
      if (ctx == null || !mounted) return;
      // Scroll only the movetext's own scrollable. The static
      // Scrollable.ensureVisible walks *all* ancestor scrollables, and when
      // this widget sits kept-alive behind a TabBarView (PGN viewer side
      // panel) that would drag the tab view back to this tab on every
      // navigation from the Analysis tab.
      final renderObject = ctx.findRenderObject();
      final scrollable = Scrollable.maybeOf(ctx);
      if (renderObject == null || scrollable == null) return;
      scrollable.position.ensureVisible(
        renderObject,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadGame());
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _movetextScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(PgnViewerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final gameIdChanged = widget.gameId != oldWidget.gameId;
    final pgnChanged = widget.pgnText != oldWidget.pgnText;

    // Skip the reload when the incoming movetext is one this widget just
    // emitted (an annotation / mainline edit flowing back through onComments
    // Changed): reloading would reset the cursor to the start of the game.
    final incomingMovetext = _normalizeMovetext(
      _stripHeaders(widget.pgnText ?? ''),
    );
    final isOwnEdit =
        _lastEmittedMovetext != null &&
        incomingMovetext == _lastEmittedMovetext;

    if (gameIdChanged ||
        (pgnChanged &&
            !isOwnEdit &&
            _stripHeaders(widget.pgnText ?? '') !=
                _stripHeaders(oldWidget.pgnText ?? ''))) {
      _loadGame();
    } else if (widget.moveNumber != oldWidget.moveNumber ||
        widget.isWhiteToPlay != oldWidget.isWhiteToPlay) {
      _clearAnalysis();
      if (widget.moveNumber != null && widget.isWhiteToPlay != null) {
        _jumpToMove(widget.moveNumber!, widget.isWhiteToPlay!);
      }
    }
  }

  Future<void> _loadGame() async {
    if (widget.pgnText == null && widget.gameId == null) {
      setState(() {
        _error = 'No game ID or PGN text provided';
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      String pgnText = '';

      // Prefer the full source game (looked up by id) so the viewer shows the
      // whole game; fall back to any explicit pgnText — e.g. a tactic's
      // solution-only PGN — when the source game isn't in storage (external
      // sets, custom puzzles, pruned games).
      if (widget.gameId != null && widget.gameId!.isNotEmpty) {
        pgnText = await _findGamePgn(widget.gameId!);
        if (!mounted) return;
      }
      if (pgnText.isEmpty && widget.pgnText != null) {
        pgnText = widget.pgnText!;
      }
      if (pgnText.isEmpty) {
        setState(() {
          _error = widget.gameId != null
              ? 'Game not found in PGN files'
              : 'No game ID or PGN text provided';
          _isLoading = false;
        });
        return;
      }

      final game = PgnGame.parsePgn(pgnText);
      final moveHistory = game.moves.mainline().toList();
      if (!mounted) return;

      final startPos = startPositionFromGame(game);
      final pgnVariations = extractPgnVariations(game, startPos);

      setState(() {
        _game = game;
        _moveHistory = moveHistory;
        _mainLineIndex = 0;
        _startPosition = startPos;
        _currentPosition = startPos;
        _gameInfo = _buildGameInfo(game);
        _isLoading = false;
        _variationsByPly = pgnVariations;
        _activeBranchPly = -1;
        _analysisPath = [];
      });

      // Defer the position notification so it doesn't fire during
      // didUpdateWidget's build phase (which would cause setState-during-build).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onPositionChanged?.call(_currentPosition);
        if (widget.moveNumber != null && widget.isWhiteToPlay != null) {
          _jumpToMove(widget.moveNumber!, widget.isWhiteToPlay!);
        } else if (widget.initialFen != null) {
          _jumpToFen(widget.initialFen!);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error loading PGN: $e';
        _isLoading = false;
      });
    }
  }

  // ── Game search ──

  Future<String> _findGamePgn(String gameId) async {
    try {
      final content = await StorageFactory.instance.readImportedPgns();
      if (content == null || content.isEmpty) return '';
      final games = splitPgnIntoGames(content);
      for (final gameText in games) {
        if (gameText.contains('[GameId "$gameId"]')) return gameText;
      }
    } catch (e) {
      debugPrint('Error finding game PGN: $e');
    }
    return '';
  }

  String _buildGameInfo(PgnGame game) {
    final white = (game.headers['White'] ?? '?').trim();
    final black = (game.headers['Black'] ?? '?').trim();
    final event = game.headers['Event'] ?? '';
    final wElo = game.headers['WhiteElo'];
    final bElo = game.headers['BlackElo'];
    final hasElo =
        (wElo != null && wElo.isNotEmpty && wElo != '?') ||
        (bElo != null && bElo.isNotEmpty && bElo != '?');

    // Book-style PGN detection: no ratings, no real event, and White holds a
    // chapter/theme title rather than a "Lastname, Firstname" player name.
    // These exports put the chapter theme in White and the specific
    // game/exercise in Black, so present them as title + theme subtitle
    // instead of the confusing "Theme vs Player1 - Player2 #3/4".
    final whiteIsTitle = !_isBlankHeader(white) && !_looksLikePlayerName(white);
    if (!hasElo && _isBlankHeader(event) && whiteIsTitle) {
      final chapter = _cleanChapterTitle(white);
      final annotator = game.headers['Annotator'];
      final example = _isBlankHeader(black) ? '' : black;

      String title;
      if (example.isNotEmpty && _cleanChapterTitle(example) != chapter) {
        // Specific game/exercise is the headline; chapter theme is the subtitle.
        title = '$example\n$chapter';
      } else {
        title = chapter;
      }
      if (annotator != null && annotator.isNotEmpty) {
        title = '$title\nby $annotator';
      }
      return title;
    }

    // If all meaningful headers are blank/?, don't show anything
    if (_isBlankHeader(white) && _isBlankHeader(black)) return '';

    final wStr = wElo != null && wElo.isNotEmpty && wElo != '?'
        ? '$white ($wElo)'
        : white;
    final bStr = bElo != null && bElo.isNotEmpty && bElo != '?'
        ? '$black ($bElo)'
        : black;
    final date = formatPgnDate(game.headers['Date']);
    final result = game.headers['Result'] ?? '';

    // Build detail line, omitting blank/placeholder parts
    final details = [
      event,
      date,
      result,
    ].where((s) => s.isNotEmpty && !_isBlankHeader(s)).join(' • ');

    if (_isBlankHeader(wStr) && _isBlankHeader(bStr)) {
      return details;
    }
    if (details.isEmpty) return '$wStr vs $bStr';
    return '$wStr vs $bStr\n$details';
  }

  /// Heuristic: a real player tag is "Lastname, Firstname" (contains a comma).
  /// Book chapter/exercise titles don't use that form.
  static bool _looksLikePlayerName(String value) => value.contains(',');

  /// Strip a leading ordinal like "1) ", "2. ", "3 - " from a chapter title.
  static final _chapterPrefixRe = RegExp(r'^\s*\d+\s*[).:\-]\s*');

  static String _cleanChapterTitle(String value) =>
      value.replaceFirst(_chapterPrefixRe, '').trim();

  // ── Build ──

  /// Render `_gameInfo` with the first line as a prominent title and any
  /// subsequent lines (theme, annotator, event/date) as dimmer subtitles.
  Widget _buildGameHeader(BuildContext context) {
    final lines = _gameInfo.split('\n');
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          lines.first,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        for (final line in lines.skip(1))
          Text(
            line,
            // bodySmall is already muted (onSurfaceMuted) — dimming it further
            // with alpha would drop below WCAG AA at this 12px size.
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading game...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, size: 64, color: AppColors.danger),
            const SizedBox(height: 16),
            Text(
              _error!,
              style: const TextStyle(color: AppColors.danger),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (_game == null) {
      return const Center(child: Text('No game loaded'));
    }

    _scheduleScrollCurrentMoveIntoView();

    return Column(
      children: [
        if (_gameInfo.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(8),
            child: _buildGameHeader(context),
          ),
        Expanded(
          // SelectionArea lets the user drag-select movetext / comments and
          // copy with Ctrl+C; move taps still hit the inner GestureDetectors.
          child: SelectionArea(
            child: SingleChildScrollView(
              controller: _movetextScrollController,
              padding: const EdgeInsets.all(8),
              child: PgnMovetextView(
                game: _game,
                moveHistory: _moveHistory,
                variationsByPly: _variationsByPly,
                mainLineIndex: _mainLineIndex,
                currentMoveKey: _currentMoveKey,
                analysisPath: _analysisPath,
                editingCommentIndex: _editingCommentIndex,
                canEditComments: widget.onCommentsChanged != null,
                bookFormatting: widget.bookFormatting,
                startingMoveNumber: _startPosition.fullmoves,
                startingWhiteTurn: _startPosition.turn == Side.white,
                startPosition: _startPosition,
                onMainLineMoveClicked: _onMainLineMoveClicked,
                onShowMoveContextMenu: _showMoveContextMenu,
                onSaveComment: _saveComment,
                onCancelEditingComment: _cancelEditingComment,
                onGoToAnalysisNode: _goToAnalysisNode,
                onShowVariationContextMenu: _showVariationContextMenu,
                revealedPly: widget.revealedPly,
                onPlayInlineLine: _playInlineLine,
                activeInlineLine: _inlineActive
                    ? (
                        firstMoveNumber: _inlineFirstMoveNumber,
                        firstIsWhite: _inlineFirstIsWhite,
                        sans: _inlineSans,
                        cursor: _inlineCursor,
                        anchorFen: _inlineAnchorFen,
                      )
                    : null,
              ),
            ),
          ),
        ),
        ?_buildBranchChips(),
        if (_isInVariation)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: SizedBox(
              width: double.infinity,
              child: Tooltip(
                message: 'Return to mainline (R)',
                waitDuration: const Duration(milliseconds: 400),
                child: FilledButton.tonalIcon(
                  onPressed: _returnToMainline,
                  icon: const Icon(Icons.subdirectory_arrow_left, size: 22),
                  label: const Text('Return to mainline'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.surfaceContainer,
                    foregroundColor: AppTextStyles.ink,
                    textStyle: AppTextStyles.bodyStrong.copyWith(fontSize: 15),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(
                        color: AppColors.onSurfaceMuted.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (widget.showStartEndButtons)
                IconButton(
                  onPressed: _canGoBack ? _goToStart : null,
                  icon: const Icon(Icons.skip_previous),
                  iconSize: 30,
                  tooltip: 'Start (Home)',
                ),
              IconButton(
                onPressed: _canGoBack ? _goBack : null,
                icon: const Icon(Icons.chevron_left),
                iconSize: 32,
                tooltip: 'Back (←)',
              ),
              IconButton(
                onPressed: _canGoForward ? _goForward : null,
                icon: const Icon(Icons.chevron_right),
                iconSize: 32,
                tooltip: 'Forward (→)',
              ),
              if (widget.showStartEndButtons)
                IconButton(
                  onPressed: _canGoForward ? _goToEnd : null,
                  icon: const Icon(Icons.skip_next),
                  iconSize: 30,
                  tooltip: 'End (End)',
                ),
            ],
          ),
        ),
        if (widget.editMode && widget.onCommentsChanged != null)
          _buildAnnotationPanel(),
      ],
    );
  }
}
