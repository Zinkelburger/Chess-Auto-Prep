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
import 'package:chess_auto_prep/widgets/pgn/add_to_study_dialog.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_movetext_view.dart';
import 'package:chess_auto_prep/core/pgn/pgn_variation_extractor.dart';

class PgnViewerWidgetController {
  _PgnViewerWidgetState? _state;

  void _attach(_PgnViewerWidgetState state) {
    _state = state;
  }

  void _detach(_PgnViewerWidgetState state) {
    if (_state == state) {
      _state = null;
    }
  }

  void goBack() {
    _state?._goBack();
  }

  void goForward() {
    _state?._goForward();
  }

  void addEphemeralMove(String san) {
    _state?._addAnalysisMove(san);
  }

  String? get currentFen => _state?._currentPosition.fen;

  void clearEphemeralMoves() {
    _state?._clearAnalysis();
  }

  void jumpToMove(int moveNumber, bool isWhiteToPlay) {
    final state = _state;
    if (state == null) return;
    state._clearAnalysis();
    state._jumpToMove(moveNumber, isWhiteToPlay);
  }

  /// Navigate directly to a mainline position by half-move index (0-based
  /// number of moves played from the start).
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

  int get mainLineIndex => _state?._mainLineIndex ?? 0;

  int get currentMainLineIndex => mainLineIndex;

  int get mainLineLength => _state?._moveHistory.length ?? 0;

  /// Mainline move SANs in order (for solitaire mode validation).
  List<String> get mainLineMoves =>
      _state?._moveHistory.map((m) => m.san).toList() ?? const [];

  /// Number of moves deep into the current variation (0 if on mainline).
  int get variationDepth => _state?._analysisPath.length ?? 0;

  /// True when navigation is inside a variation / inline preview (off mainline).
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
  void recordVariationMove(String san) => _state?._recordVariationMove(san);

  /// Append solitaire guess notes to mainline move comments ([notes] keyed by
  /// 0-based move index) and persist through the standard movetext serializer,
  /// keeping the game's own annotations intact.
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
  final bool protectOriginal;

  /// When non-null, movetext hides moves at index >= this value.
  final int? revealedPly;

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
    this.protectOriginal = true,
    this.revealedPly,
  });

  @override
  State<PgnViewerWidget> createState() => _PgnViewerWidgetState();
}

class _PgnViewerWidgetState extends State<PgnViewerWidget>
    with AutomaticKeepAliveClientMixin {
  PgnGame? _game;
  List<PgnNodeData> _moveHistory = [];
  int _mainLineIndex = 0;
  Position _currentPosition = Chess.initial;
  Position _startPosition = Chess.initial;
  String _gameInfo = '';
  bool _isLoading = true;
  String? _error;

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

  static final _headerLineRe = RegExp(r'^\s*\[.*\]\s*$', multiLine: true);

  static String _stripHeaders(String pgn) =>
      pgn.replaceAll(_headerLineRe, '').trim();

  @override
  void didUpdateWidget(PgnViewerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final gameIdChanged = widget.gameId != oldWidget.gameId;
    final pgnChanged = widget.pgnText != oldWidget.pgnText;

    // Skip the reload when the incoming movetext is one this widget just
    // emitted (an annotation / mainline edit flowing back through onComments
    // Changed): reloading would reset the cursor to the start of the game.
    final incomingMovetext = _normalizeMovetext(_stripHeaders(widget.pgnText ?? ''));
    final isOwnEdit =
        _lastEmittedMovetext != null && incomingMovetext == _lastEmittedMovetext;

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
      String pgnText;

      if (widget.pgnText != null) {
        pgnText = widget.pgnText!;
      } else {
        pgnText = await _findGamePgn(widget.gameId!);
        if (!mounted) return;
        if (pgnText.isEmpty) {
          setState(() {
            _error = 'Game not found in PGN files';
            _isLoading = false;
          });
          return;
        }
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
    final hasElo = (wElo != null && wElo.isNotEmpty && wElo != '?') ||
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
      if (annotator != null && annotator.isNotEmpty) title = '$title\nby $annotator';
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
    final details = [event, date, result]
        .where((s) => s.isNotEmpty && !_isBlankHeader(s))
        .join(' • ');

    if (_isBlankHeader(wStr) && _isBlankHeader(bStr)) {
      return details;
    }
    if (details.isEmpty) return '$wStr vs $bStr';
    return '$wStr vs $bStr\n$details';
  }

  static bool _isBlankHeader(String value) {
    final v = value.trim();
    return v.isEmpty || v == '?' || RegExp(r'^[?. *]+$').hasMatch(v);
  }

  /// Heuristic: a real player tag is "Lastname, Firstname" (contains a comma).
  /// Book chapter/exercise titles don't use that form.
  static bool _looksLikePlayerName(String value) => value.contains(',');

  /// Strip a leading ordinal like "1) ", "2. ", "3 - " from a chapter title.
  static final _chapterPrefixRe = RegExp(r'^\s*\d+\s*[).:\-]\s*');

  static String _cleanChapterTitle(String value) =>
      value.replaceFirst(_chapterPrefixRe, '').trim();

  // ── Navigation ──

  void _jumpToMove(int moveNumber, bool isWhiteToPlay) {
    if (_moveHistory.isEmpty) return;
    int targetPly = (moveNumber - 1) * 2;
    if (!isWhiteToPlay) targetPly += 1;
    targetPly = targetPly.clamp(0, _moveHistory.length);
    _goToMainLineMove(targetPly);
  }

  void _jumpToFen(String targetFen) {
    if (_moveHistory.isEmpty) return;
    final target = normalizeFen(targetFen);
    Position pos = _startPosition;
    for (int i = 0; i < _moveHistory.length; i++) {
      final san = _moveHistory[i].san;
      if (san == '--') continue;
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
      if (normalizeFen(pos.fen) == target) {
        _goToMainLineMove(i + 1);
        return;
      }
    }
  }

  void _goToMainLineMove(int moveIndex) {
    // Solitaire: never walk the board past the revealed frontier.
    if (widget.revealedPly != null && moveIndex > widget.revealedPly!) {
      moveIndex = widget.revealedPly!;
    }
    if (moveIndex < 0 || moveIndex > _moveHistory.length) return;
    Position pos = _startPosition;
    for (int i = 0; i < moveIndex; i++) {
      final san = _moveHistory[i].san;
      if (san == '--') continue;
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
    }
    setState(() {
      _mainLineIndex = moveIndex;
      _currentPosition = pos;
      _analysisPath = [];
      _activeBranchPly = -1;
      _clearInlineLine();
    });
    widget.onPositionChanged?.call(pos);
  }

  void _goToAnalysisNode(MoveNode targetNode, int branchPly) {
    final roots = _variationsByPly[branchPly];
    if (roots == null) return;

    final path = _findPathToNode(targetNode, roots);
    if (path == null) return;

    Position pos = _startPosition;
    for (int i = 0; i < branchPly; i++) {
      final san = _moveHistory[i].san;
      if (san == '--') continue;
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
    }
    for (final node in path) {
      if (node.san == '--') continue;
      final move = pos.parseSan(node.san);
      if (move == null) break;
      pos = pos.play(move);
    }

    setState(() {
      _mainLineIndex = branchPly;
      _activeBranchPly = branchPly;
      _currentPosition = pos;
      _analysisPath = path;
      _clearInlineLine();
    });
    widget.onPositionChanged?.call(pos);
  }

  List<MoveNode>? _findPathToNode(
      MoveNode target, List<MoveNode> roots) {
    for (final root in roots) {
      final path = _findPathRecursive(root, target, []);
      if (path != null) return path;
    }
    return null;
  }

  List<MoveNode>? _findPathRecursive(
      MoveNode current, MoveNode target, List<MoveNode> pathSoFar) {
    final newPath = [...pathSoFar, current];
    if (current.id == target.id) return newPath;
    for (final child in current.children) {
      final result = _findPathRecursive(child, target, newPath);
      if (result != null) return result;
    }
    return null;
  }

  void _goToStart() {
    _goToMainLineMove(0);
  }

  /// True when navigation is currently off the mainline — inside a saved /
  /// analysis variation or an inline comment-line preview.
  bool get _isInVariation => _analysisPath.isNotEmpty || _inlineActive;

  /// Jump from the current variation (or inline preview) back to the mainline,
  /// landing on the move where the current line branched off.
  void _returnToMainline() {
    int target;
    if (_analysisPath.isNotEmpty) {
      target = _activeBranchPly >= 0 ? _activeBranchPly : _mainLineIndex;
    } else if (_inlineActive) {
      target = _inlineBaseIndex;
    } else {
      return;
    }
    _goToMainLineMove(target.clamp(0, _moveHistory.length));
  }

  /// The continuation candidates at the current position, in the order the
  /// fork bar shows them (mainline continuation first). Shared by the chip
  /// rendering and the 1–9 keyboard shortcuts so both always agree.
  List<({String san, Color color, VoidCallback onTap, bool emphasized})>
      _branchCandidates() {
    final candidates =
        <({String san, Color color, VoidCallback onTap, bool emphasized})>[];
    if (_analysisPath.isEmpty && !_inlineActive) {
      // On the mainline: the next mainline move + any sidelines branching here.
      // In solitaire the frontier ply is still being guessed: its mainline
      // move and the source game's alternatives stay hidden there.
      final ply = _mainLineIndex;
      final atSolitaireFrontier =
          widget.revealedPly != null && ply >= widget.revealedPly!;
      if (!atSolitaireFrontier &&
          ply < _moveHistory.length &&
          _moveHistory[ply].san != '--') {
        candidates.add((
          san: _moveHistory[ply].san,
          color: AppColors.pgnMainLine,
          onTap: () => _goToMainLineMove(ply + 1),
          emphasized: true,
        ));
      }
      for (final root in _variationsByPly[ply] ?? const <MoveNode>[]) {
        if (root.san == '--') continue;
        if (atSolitaireFrontier && !root.isEphemeral) continue;
        candidates.add((
          san: root.san,
          color: root.isEphemeral
              ? AppColors.pgnEphemeralMove
              : AppColors.pgnVariation,
          onTap: () => _goToAnalysisNode(root, ply),
          emphasized: false,
        ));
      }
    } else if (_analysisPath.isNotEmpty) {
      // Inside a variation: the children of the current node.
      for (final child in _analysisPath.last.children) {
        if (child.san == '--') continue;
        candidates.add((
          san: child.san,
          color: child.isEphemeral
              ? AppColors.pgnEphemeralMove
              : AppColors.pgnVariation,
          onTap: () => _goToAnalysisNode(child, _activeBranchPly),
          emphasized: false,
        ));
      }
    }
    return candidates;
  }

  /// The moves that continue from the current position, as tappable chips.
  /// Returns null unless there's a genuine branch (≥2 options) so the bar stays
  /// unobtrusive on linear lines. Mirrors Lichess' inline branch picker.
  /// Each chip carries a keycap badge; keys 1–9 play the matching candidate.
  Widget? _buildBranchChips() {
    final candidates = _branchCandidates();
    if (candidates.length < 2) return null;
    final chips = <Widget>[
      for (final (i, c) in candidates.indexed)
        _branchChip(c.san, c.color, c.onTap,
            emphasized: c.emphasized, shortcutNumber: i < 9 ? i + 1 : null),
    ];
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, top: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Icon(Icons.call_split, size: 13, color: AppColors.onSurfaceDim),
          ...chips,
        ],
      ),
    );
  }

  Widget _branchChip(String san, Color color, VoidCallback onTap,
      {bool emphasized = false, int? shortcutNumber}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: emphasized ? 0.20 : 0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (shortcutNumber != null) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '$shortcutNumber',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10.5,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 5),
            ],
            Text(
              san,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                color: color,
                fontWeight: emphasized ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _goBack() {
    if (_inlineActive) {
      _setInlineCursor(_inlineCursor - 1);
      return;
    }
    if (_analysisPath.isNotEmpty) {
      if (_analysisPath.length > 1) {
        final parentPath = _analysisPath.sublist(0, _analysisPath.length - 1);
        _goToAnalysisNode(parentPath.last, _activeBranchPly);
      } else {
        _goToMainLineMove(_activeBranchPly);
      }
    } else if (_mainLineIndex > 0) {
      _goToMainLineMove(_mainLineIndex - 1);
    }
  }

  void _goForward() {
    if (_inlineActive) {
      if (_inlineCursor < _inlineSans.length) {
        _setInlineCursor(_inlineCursor + 1);
      }
      return;
    }
    if (_analysisPath.isNotEmpty) {
      final current = _analysisPath.last;
      if (current.children.isNotEmpty) {
        _goToAnalysisNode(current.children.first, _activeBranchPly);
      }
    } else if (_mainLineIndex < _moveHistory.length) {
      _goToMainLineMove(_mainLineIndex + 1);
    }
  }

  void _goToEnd() {
    if (_inlineActive) {
      _setInlineCursor(_inlineSans.length);
      return;
    }
    if (_analysisPath.isNotEmpty) {
      MoveNode current = _analysisPath.last;
      while (current.children.isNotEmpty) {
        current = current.children.first;
      }
      _goToAnalysisNode(current, _activeBranchPly);
    } else {
      _goToMainLineMove(_moveHistory.length);
    }
  }

  void _onMainLineMoveClicked(int moveIndex) {
    _goToMainLineMove(moveIndex + 1);
  }

  /// Begin previewing an inline analysis line embedded in a comment. [sans] is
  /// the run's full move list (first move is [moveNumber]/[isWhite]); the board
  /// steps to the move at [clickedIndex]. Unlike a variation, this does NOT add
  /// anything to the move tree — it just walks the board through the line, so
  /// the comment keeps its rendering and the arrows step along the line.
  void _playInlineLine(
      int moveNumber, bool isWhite, List<String> sans, int clickedIndex,
      {String? anchorFen}) {
    // FEN-anchored lines start from the FEN, not a mainline position; keep the
    // mainline highlight where the user is so exiting returns there. Otherwise
    // locate the branch point by move number as before.
    final baseIndex = anchorFen != null
        ? _mainLineIndex
        : plyBeforeMove(
            moveNumber: moveNumber,
            isWhite: isWhite,
            startFullmoves: _startPosition.fullmoves,
            startWhiteToMove: _startPosition.turn == Side.white,
          ).clamp(0, _moveHistory.length);
    // Drop any ephemeral variation moves so we don't leave a stale sideline.
    _clearAnalysis();
    _inlineBaseIndex = baseIndex;
    _inlineAnchorFen = anchorFen;
    _inlineSans = sans;
    _inlineFirstMoveNumber = moveNumber;
    _inlineFirstIsWhite = isWhite;
    _setInlineCursor(clickedIndex + 1);
  }

  /// Move the inline-preview cursor to [cursor] moves played and update the
  /// board. A cursor of 0 (or below) exits preview back to the base position.
  void _setInlineCursor(int cursor) {
    cursor = cursor.clamp(0, _inlineSans.length);
    if (cursor <= 0) {
      _clearInlineLine();
      _goToMainLineMove(_inlineBaseIndex);
      return;
    }
    // Establish the base position: a comment FEN when anchored, otherwise the
    // mainline replayed up to the branch point. Then play the inline moves.
    Position pos;
    final anchorFen = _inlineAnchorFen;
    if (anchorFen != null) {
      try {
        pos = Chess.fromSetup(Setup.parseFen(anchorFen));
      } catch (_) {
        _clearInlineLine();
        _goToMainLineMove(_inlineBaseIndex);
        return;
      }
    } else {
      pos = _startPosition;
      for (int i = 0; i < _inlineBaseIndex; i++) {
        final san = _moveHistory[i].san;
        if (san == '--') continue;
        final m = pos.parseSan(san);
        if (m == null) break;
        pos = pos.play(m);
      }
    }
    int played = 0;
    for (int i = 0; i < cursor; i++) {
      final m = pos.parseSan(_inlineSans[i]);
      if (m == null) break;
      pos = pos.play(m);
      played++;
    }
    if (!mounted) return;
    setState(() {
      _mainLineIndex = _inlineBaseIndex;
      _analysisPath = [];
      _activeBranchPly = -1;
      _inlineCursor = played;
      _currentPosition = pos;
    });
    widget.onPositionChanged?.call(pos);
  }

  void _clearInlineLine() {
    _inlineSans = const [];
    _inlineCursor = 0;
    _inlineAnchorFen = null;
  }

  bool get _canGoBack {
    return _inlineActive || _analysisPath.isNotEmpty || _mainLineIndex > 0;
  }

  bool get _canGoForward {
    if (_inlineActive) return _inlineCursor < _inlineSans.length;
    if (_analysisPath.isNotEmpty && _analysisPath.last.children.isNotEmpty) {
      return true;
    }
    final mainLimit = widget.revealedPly != null
        ? widget.revealedPly!.clamp(0, _moveHistory.length)
        : _moveHistory.length;
    if (_analysisPath.isEmpty && _mainLineIndex < mainLimit) {
      return true;
    }
    return false;
  }

  // ── Adding user moves ──

  void _addAnalysisMove(String san) {
    final parsedMove = _currentPosition.parseSan(san);
    if (parsedMove == null) return;

    Position newPos;
    try {
      newPos = _currentPosition.play(parsedMove);
    } catch (_) {
      return;
    }
    final fenAfter = newPos.fen;

    // In edit mode, moves become permanent edits saved to disk: extending the
    // mainline at its end, or adding a real (non-ephemeral) sideline elsewhere.
    // Outside edit mode, moves are ephemeral scratch analysis (never saved).
    final editing = widget.editMode &&
        widget.onCommentsChanged != null &&
        widget.revealedPly == null;

    // Edit mode at the end of the mainline: extend the mainline itself rather
    // than start a sideline. Excluded while an inline comment-preview is active:
    // there _currentPosition is the preview board (not the mainline tail), so
    // appending `san` here would splice a move that is illegal from the real
    // last position into the persisted mainline.
    if (editing &&
        _analysisPath.isEmpty &&
        !_inlineActive &&
        _mainLineIndex == _moveHistory.length) {
      setState(() {
        _clearInlineLine();
        _moveHistory.add(PgnNodeData(san: san));
        _mainLineIndex = _moveHistory.length;
        _currentPosition = newPos;
      });
      _notifyCommentsChanged();
      widget.onPositionChanged?.call(newPos);
      return;
    }

    setState(() {
      _clearInlineLine();
      if (_analysisPath.isEmpty) {
        // Starting new variation from mainline
        final ply = _mainLineIndex;
        final roots = _variationsByPly.putIfAbsent(ply, () => []);

        // Check if this move already exists
        MoveNode? existing;
        for (final root in roots) {
          if (root.san == san) {
            existing = root;
            break;
          }
        }

        if (existing != null) {
          _analysisPath = [existing];
        } else {
          final newNode =
              MoveNode(san: san, fen: fenAfter, isEphemeral: !editing);
          roots.add(newNode);
          _analysisPath = [newNode];
        }
        _activeBranchPly = ply;
      } else {
        // Extending current variation
        final current = _analysisPath.last;
        final (node, _) =
            current.addChild(san, fenAfter, isEphemeral: !editing);
        _analysisPath = [..._analysisPath, node];
      }
      _currentPosition = newPos;
    });
    if (editing) _notifyCommentsChanged();
    widget.onPositionChanged?.call(newPos);
  }

  /// Add [san] as an ephemeral variation root at the current mainline ply
  /// without navigating into it — the board stays on the pre-move position.
  /// Used by solitaire to show wrong attempts as live variations.
  void _recordVariationMove(String san) {
    if (_analysisPath.isNotEmpty || _inlineActive) return;
    final parsedMove = _currentPosition.parseSan(san);
    if (parsedMove == null) return;
    final Position newPos;
    try {
      newPos = _currentPosition.play(parsedMove);
    } catch (_) {
      return;
    }
    final ply = _mainLineIndex;
    final roots = _variationsByPly.putIfAbsent(ply, () => []);
    if (roots.any((r) => r.san == san)) return;
    setState(() {
      roots.add(MoveNode(san: san, fen: newPos.fen, isEphemeral: true));
    });
  }

  // ── Clear / delete ──

  void _clearAnalysis() {
    setState(() {
      // Remove only ephemeral nodes from all plies
      final keysToRemove = <int>[];
      for (final entry in _variationsByPly.entries) {
        entry.value.removeWhere((n) => n.isEphemeral);
        // Also remove ephemeral children from PGN nodes
        for (final root in entry.value) {
          _removeEphemeralChildren(root);
        }
        if (entry.value.isEmpty) keysToRemove.add(entry.key);
      }
      for (final k in keysToRemove) {
        _variationsByPly.remove(k);
      }
      _analysisPath = [];
      _activeBranchPly = -1;
      _clearInlineLine();
    });
  }

  void _removeEphemeralChildren(MoveNode node) {
    node.children.removeWhere((c) => c.isEphemeral);
    for (final child in node.children) {
      _removeEphemeralChildren(child);
    }
  }

  bool _subtreeHasEphemeral(MoveNode node) {
    if (node.isEphemeral) return true;
    for (final child in node.children) {
      if (_subtreeHasEphemeral(child)) return true;
    }
    return false;
  }

  void _deleteAnalysisNode(int nodeId) {
    setState(() {
      for (final entry in _variationsByPly.entries) {
        final ply = entry.key;
        final roots = entry.value;

        final lengthBefore = roots.length;
        roots.removeWhere((n) => n.id == nodeId);
        if (roots.length < lengthBefore) {
          // If current path includes the deleted node, exit variation
          if (_activeBranchPly == ply && _analysisPath.isNotEmpty) {
            _analysisPath = [];
            _activeBranchPly = -1;
          }
          return;
        }

        // Search deeper
        for (final root in roots) {
          if (_removeNodeRecursive(root.children, nodeId)) {
            final idx = _analysisPath.indexWhere((n) => n.id == nodeId);
            if (idx != -1) {
              if (idx == 0) {
                _analysisPath = [];
                _activeBranchPly = -1;
              } else {
                _analysisPath = _analysisPath.sublist(0, idx);
                _goToAnalysisNode(_analysisPath.last, _activeBranchPly);
              }
            }
            return;
          }
        }
      }
    });
  }

  bool _removeNodeRecursive(List<MoveNode> nodes, int targetId) {
    for (final node in nodes) {
      if (node.children.any((c) => c.id == targetId)) {
        node.children.removeWhere((c) => c.id == targetId);
        return true;
      }
      if (_removeNodeRecursive(node.children, targetId)) return true;
    }
    return false;
  }

  // ── Move comment editing ──

  int? _editingCommentIndex;
  int? _selectedMoveIndex; // for annotation toolbar in edit mode

  /// The last movetext this widget emitted via [onCommentsChanged] (whitespace-
  /// normalized). Used so that when our own persisted edit flows back in as an
  /// updated `pgnText`, `didUpdateWidget` recognizes it and skips the reload
  /// that would otherwise reset the cursor to the start of the game.
  String? _lastEmittedMovetext;

  static String _normalizeMovetext(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();

  void _startEditingComment(int moveIndex) {
    setState(() => _editingCommentIndex = moveIndex);
  }

  void _saveComment(int moveIndex, String newComment) {
    if (moveIndex < 0 || moveIndex >= _moveHistory.length) return;
    final moveData = _moveHistory[moveIndex];
    final trimmed = newComment.trim();
    setState(() {
      if (trimmed.isEmpty) {
        moveData.comments?.clear();
      } else {
        if (moveData.comments == null || moveData.comments!.isEmpty) {
          moveData.comments = [trimmed];
        } else {
          moveData.comments![0] = trimmed;
        }
      }
      _editingCommentIndex = null;
    });
    _notifyCommentsChanged();
  }

  void _cancelEditingComment() {
    setState(() => _editingCommentIndex = null);
  }

  /// Append guess notes to mainline move comments and persist once, keeping
  /// the game's own annotations (unlike replacing the whole movetext).
  void _addGuessAnnotations(Map<int, String> notes) {
    if (notes.isEmpty || _moveHistory.isEmpty) return;
    setState(() {
      notes.forEach((index, note) {
        if (index < 0 || index >= _moveHistory.length) return;
        final moveData = _moveHistory[index];
        final existing =
            (moveData.comments == null || moveData.comments!.isEmpty)
                ? ''
                : moveData.comments!.first;
        if (existing.contains(note)) return;
        final merged = existing.isEmpty ? note : '$existing $note';
        if (moveData.comments == null || moveData.comments!.isEmpty) {
          moveData.comments = [merged];
        } else {
          moveData.comments![0] = merged;
        }
      });
    });
    _notifyCommentsChanged();
  }

  void _toggleNag(int moveIndex, int nagId) {
    if (moveIndex < 0 || moveIndex >= _moveHistory.length) return;
    final moveData = _moveHistory[moveIndex];
    setState(() {
      final nags = moveData.nags ?? [];
      if (nags.contains(nagId)) {
        nags.remove(nagId);
      } else {
        // Remove other move-quality NAGs (1-6) before adding
        nags.removeWhere((n) => n >= 1 && n <= 6);
        nags.add(nagId);
      }
      moveData.nags = nags.isEmpty ? null : nags;
    });
    _notifyCommentsChanged();
  }

  void _selectMoveForAnnotation(int moveIndex) {
    setState(() {
      if (_selectedMoveIndex == moveIndex) {
        _selectedMoveIndex = null;
      } else {
        _selectedMoveIndex = moveIndex;
      }
    });
  }

  RelativeRect _menuPosition(Offset globalPosition) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );
  }

  static PopupMenuItem<String> _menuItem(
      String value, IconData icon, String label,
      {bool enabled = true, Color? color}) {
    final effectiveColor = enabled ? color : Colors.grey[700];
    return PopupMenuItem(
      value: value,
      enabled: enabled,
      child: Row(
        children: [
          Icon(icon, size: 18, color: effectiveColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: effectiveColor != null
                  ? TextStyle(color: effectiveColor)
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  void _showMoveContextMenu(int moveIndex, Offset globalPosition) {
    final protectOriginal = widget.protectOriginal;
    final hasBranch = _variationsByPly.containsKey(moveIndex + 1);
    final line = _moveHistory.sublist(0, moveIndex + 1);

    showMenu<String>(
      context: context,
      position: _menuPosition(globalPosition),
      items: [
        _menuItem('copy_line', Icons.copy_outlined, 'Copy line PGN'),
        _menuItem('add_to_study', Icons.menu_book_outlined,
            'Add to study…'),
        if (widget.editMode) ...[
          const PopupMenuDivider(),
          _menuItem('comment', Icons.comment_outlined, 'Comment'),
          _menuItem('annotate', Icons.edit_note, 'Annotate'),
          if (hasBranch) ...[
            const PopupMenuDivider(),
            _menuItem('promote', Icons.arrow_upward, 'Promote variation',
                enabled: !protectOriginal),
          ],
          const PopupMenuDivider(),
          _menuItem('delete', Icons.delete_outline, 'Delete move',
              enabled: !protectOriginal, color: Colors.red),
        ] else if (widget.onCommentsChanged != null) ...[
          const PopupMenuDivider(),
          _menuItem('comment', Icons.comment_outlined, 'Comment'),
        ],
      ],
    ).then((action) {
      if (action == 'copy_line') {
        _copyLinePgn(line);
      } else if (action == 'add_to_study') {
        _addLineToStudy(line);
      } else if (action == 'comment') {
        _startEditingComment(moveIndex);
      } else if (action == 'annotate') {
        _selectMoveForAnnotation(moveIndex);
      }
      // promote and delete require tree manipulation (future)
    });
  }

  void _showVariationContextMenu(
      MoveNode node, int branchPly, Offset globalPosition) {
    final line = _lineToVariationNode(node, branchPly);
    if (line == null) return;

    showMenu<String>(
      context: context,
      position: _menuPosition(globalPosition),
      items: [
        _menuItem('copy_line', Icons.copy_outlined, 'Copy line PGN'),
        _menuItem('add_to_study', Icons.menu_book_outlined,
            'Add to study…'),
        if (node.isEphemeral) ...[
          const PopupMenuDivider(),
          _menuItem('delete', Icons.delete_outline, 'Delete variation',
              color: Colors.red),
          _menuItem('clear_all', Icons.clear_all, 'Clear all analysis'),
        ],
      ],
    ).then((action) {
      if (action == 'copy_line') {
        _copyLinePgn(line);
      } else if (action == 'add_to_study') {
        _addLineToStudy(line);
      } else if (action == 'delete') {
        _deleteAnalysisNode(node.id);
      } else if (action == 'clear_all') {
        _clearAnalysis();
      }
    });
  }

  // ── Copy line / add line to study ──

  /// Move data from the game start to [node]: the mainline up to the branch
  /// point, then the variation path. Null when the node can't be located.
  List<PgnNodeData>? _lineToVariationNode(MoveNode node, int branchPly) {
    final roots = _variationsByPly[branchPly];
    if (roots == null) return null;
    final path = _findPathToNode(node, roots);
    if (path == null) return null;
    return [
      for (int i = 0; i < branchPly && i < _moveHistory.length; i++)
        _moveHistory[i],
      for (final n in path)
        PgnNodeData(
          san: n.san,
          comments: (n.comment != null && n.comment!.trim().isNotEmpty)
              ? [n.comment!.trim()]
              : null,
          nags: (n.nags != null && n.nags!.isNotEmpty)
              ? List<int>.from(n.nags!)
              : null,
        ),
    ];
  }

  /// Serialize a single line to PGN: `[FEN]`/`[SetUp]` headers when the game
  /// starts from a custom position, then numbered movetext (comments and
  /// NAGs of the source moves included).
  String _buildLinePgn(List<PgnNodeData> line) {
    final headers = <String, String>{};
    final fen = _game?.headers['FEN'];
    if (fen != null && fen.isNotEmpty) {
      headers['FEN'] = fen;
      headers['SetUp'] = '1';
    }
    final root = PgnNode<PgnNodeData>();
    PgnNode<PgnNodeData> parent = root;
    for (final data in line) {
      final child = PgnChildNode<PgnNodeData>(data);
      parent.children.add(child);
      parent = child;
    }
    return PgnGame<PgnNodeData>(
      headers: headers,
      moves: root,
      comments: const [],
    ).makePgn().trim();
  }

  String _suggestChapterName(List<PgnNodeData> line) {
    final coords = coordsAtPly(
      ply: line.length - 1,
      startFullmoves: _startPosition.fullmoves,
      startWhiteToMove: _startPosition.turn == Side.white,
    );
    final moveLabel =
        '${coords.moveNumber}${coords.isWhite ? '.' : '...'}${line.last.san}';
    final white = _game?.headers['White'] ?? '';
    final black = _game?.headers['Black'] ?? '';
    if (!_isBlankHeader(white) && !_isBlankHeader(black)) {
      return '$white – $black: $moveLabel';
    }
    return 'Line to $moveLabel';
  }

  Future<void> _copyLinePgn(List<PgnNodeData> line) async {
    if (line.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _buildLinePgn(line)));
    if (!mounted) return;
    showAppSnackBar(context, 'Line copied to clipboard');
  }

  Future<void> _addLineToStudy(List<PgnNodeData> line) async {
    if (line.isEmpty) return;
    final pgn = _buildLinePgn(line);
    final result = await showDialog<AddToStudyResult>(
      context: context,
      builder: (_) =>
          AddToStudyDialog(initialChapterName: _suggestChapterName(line)),
    );
    if (result == null || !mounted) return;

    final study = context.read<StudyController>();
    final appState = context.read<AppState>();
    try {
      final path = result.existingPath ??
          await StorageFactory.instance.studyFilePath(result.newStudyName!);
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

  void _notifyCommentsChanged() {
    if (widget.onCommentsChanged == null || _moveHistory.isEmpty) return;
    final movetext = _buildAnnotatedMovetext();
    _lastEmittedMovetext = _normalizeMovetext(movetext);
    widget.onCommentsChanged!(movetext);
  }

  /// Serialize the current mainline *and* every saved sideline variation (with
  /// their comments and NAGs) back to PGN movetext. Uses dartchess'
  /// [PgnGame.makePgn] — which handles variations, NAGs, and move numbering for
  /// games that start from a custom FEN — then strips the header block so the
  /// caller can splice it back under the game's existing headers.
  ///
  /// Ephemeral (scratch) analysis nodes are excluded; only permanent edits are
  /// written.
  String _buildAnnotatedMovetext() {
    final headers = <String, String>{};
    final fen = _game?.headers['FEN'];
    if (fen != null && fen.isNotEmpty) headers['FEN'] = fen;
    final result = _game?.headers['Result'];
    if (result != null && result.isNotEmpty) headers['Result'] = result;

    final serializable = PgnGame<PgnNodeData>(
      headers: headers,
      moves: _buildPgnTree(),
      comments: _game?.comments ?? const [],
    );
    return _stripHeaders(serializable.makePgn()).trim();
  }

  /// Rebuild a dartchess move tree from the flat mainline [_moveHistory] plus
  /// the per-ply sidelines in [_variationsByPly]. Inverts [extractPgnVariations]:
  /// sidelines keyed at ply `p` are siblings of the mainline move at index `p`
  /// (i.e. `children[1..]` of the same parent). Ephemeral nodes are skipped.
  PgnNode<PgnNodeData> _buildPgnTree() {
    final root = PgnNode<PgnNodeData>();
    PgnNode<PgnNodeData> parent = root;

    void addSidelines(int ply) {
      final roots = _variationsByPly[ply];
      if (roots == null) return;
      for (final sideline in roots) {
        if (sideline.isEphemeral) continue;
        parent.children.add(_moveNodeToPgnChild(sideline));
      }
    }

    for (int i = 0; i < _moveHistory.length; i++) {
      final mainChild = PgnChildNode<PgnNodeData>(_moveHistory[i]);
      parent.children.add(mainChild); // index 0 = mainline continuation
      addSidelines(i); // alternatives to _moveHistory[i], sharing `parent`
      parent = mainChild;
    }
    // Sidelines branching after the final mainline move (user-added only).
    addSidelines(_moveHistory.length);
    return root;
  }

  PgnChildNode<PgnNodeData> _moveNodeToPgnChild(MoveNode node) {
    final hasComment = node.comment != null && node.comment!.trim().isNotEmpty;
    final hasNags = node.nags != null && node.nags!.isNotEmpty;
    final child = PgnChildNode<PgnNodeData>(PgnNodeData(
      san: node.san,
      comments: hasComment ? [node.comment!.trim()] : null,
      nags: hasNags ? List<int>.from(node.nags!) : null,
    ));
    for (final c in node.children) {
      if (c.isEphemeral) continue;
      child.children.add(_moveNodeToPgnChild(c));
    }
    return child;
  }

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
          style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w600),
          textAlign: TextAlign.center,
        ),
        for (final line in lines.skip(1))
          Text(
            line,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
            ),
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
            const Icon(Icons.error, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center),
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
              selectedMoveIndex: _selectedMoveIndex,
              editingCommentIndex: _editingCommentIndex,
              editMode: widget.editMode,
              canEditComments: widget.onCommentsChanged != null,
              startingMoveNumber: _startPosition.fullmoves,
              startingWhiteTurn: _startPosition.turn == Side.white,
              startPosition: _startPosition,
              onMainLineMoveClicked: _onMainLineMoveClicked,
              onSelectMoveForAnnotation: _selectMoveForAnnotation,
              onShowMoveContextMenu: _showMoveContextMenu,
              onStartEditingComment: _startEditingComment,
              onToggleNag: _toggleNag,
              onSaveComment: _saveComment,
              onCancelEditingComment: _cancelEditingComment,
              onDismissAnnotation: () =>
                  setState(() => _selectedMoveIndex = null),
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
        ?_buildBranchChips(),
        if (_isInVariation)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 8, right: 8, top: 2),
              child: Tooltip(
                message: 'Return to mainline (R)',
                waitDuration: const Duration(milliseconds: 400),
                child: OutlinedButton.icon(
                  onPressed: _returnToMainline,
                  icon: const Icon(Icons.subdirectory_arrow_left, size: 16),
                  label: const Text('Return to mainline'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.pgnMainLine,
                    side: BorderSide(
                        color: AppColors.pgnMainLine.withValues(alpha: 0.6)),
                    textStyle: const TextStyle(fontSize: 12),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ),
          ),
        Container(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (widget.showStartEndButtons)
                IconButton(
                    onPressed: _canGoBack ? _goToStart : null,
                    icon: const Icon(Icons.skip_previous),
                    tooltip: 'Start (Home)'),
              IconButton(
                  onPressed: _canGoBack ? _goBack : null,
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Back (←)'),
              IconButton(
                  onPressed: _canGoForward ? _goForward : null,
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Forward (→)'),
              if (widget.showStartEndButtons)
                IconButton(
                    onPressed: _canGoForward ? _goToEnd : null,
                    icon: const Icon(Icons.skip_next),
                    tooltip: 'End (End)'),
            ],
          ),
        ),
      ],
    );
  }
}
