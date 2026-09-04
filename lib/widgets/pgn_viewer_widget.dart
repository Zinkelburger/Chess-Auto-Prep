import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/services/stored_game_lookup.dart';
import 'package:chess_auto_prep/utils/app_messages.dart';
import 'package:chess_auto_prep/utils/pgn_date_utils.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart'
    show
        coordsAtPly,
        isNullMoveSan,
        playSanOrNullMove,
        plyBeforeMove,
        recentMoveTrailSquares;
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/theme/app_text_styles.dart';
import 'package:chess_auto_prep/theme/pgn_text_styles.dart';
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart'
    show
        commentProse,
        filterDisplayComment,
        joinComments,
        mergeCommentProse,
        stripEngineTokens;
import 'package:chess_auto_prep/widgets/info_hint.dart';
import 'package:chess_auto_prep/widgets/study/add_to_study_flow.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_movetext_view.dart';
import 'package:chess_auto_prep/core/pgn/pgn_viewer_handle.dart';
import 'package:chess_auto_prep/core/pgn/solitaire_reveal.dart';
import 'package:chess_auto_prep/core/pgn/solitaire_script.dart'
    as solitaire_script;
import 'package:chess_auto_prep/core/pgn/viewer_game_model.dart';

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

  @override
  void goToVariationNode(MoveNode node, int branchPly) {
    _state?._goToAnalysisNode(node, branchPly);
  }

  /// Park the mainline cursor on the position matching [fen], leaving any
  /// ephemeral analysis in place (unlike [jumpToMove], which discards it).
  ///
  /// Returns false when the loaded game never reaches that position — which
  /// is also the answer while no viewer is attached, so a caller navigating a
  /// position it cares about ("the ply this tactic starts from") can bail out
  /// instead of driving the cursor blind.
  bool goToFen(String fen) => _state?._jumpToFen(fen) ?? false;

  void deleteAnalysisNode(int nodeId) {
    _state?._deleteAnalysisNode(nodeId);
  }

  bool get hasAnalysis => _state?._m.hasAnalysis ?? false;

  /// True when the user has added ephemeral analysis lines (not from PGN).
  @override
  bool get hasEphemeralMoves => _state?._m.hasEphemeralMoves ?? false;

  @override
  int get mainLineIndex => _state?._mainLineIndex ?? 0;

  int get currentMainLineIndex => mainLineIndex;

  @override
  int get mainLineLength => _state?._moveHistory.length ?? 0;

  /// Mainline move SANs in order (for solitaire mode validation).
  @override
  List<String> get mainLineMoves =>
      _state?._moveHistory.map((m) => m.san).toList() ?? const [];

  /// From/to squares of the half-move that produced the current position
  /// (mainline, variation, or inline preview) — for the subtle last-move
  /// highlight via [ChessBoardWidget.recentMoveSquares]. Empty at game start.
  @override
  Set<String> get recentMoveSquares => _state?._recentMoveSquares() ?? const {};

  /// Number of moves deep into the current variation (0 if on mainline).
  int get variationDepth => _state?._analysisPath.length ?? 0;

  /// True when navigation is inside a variation / inline preview (off mainline).
  @override
  bool get inVariation => _state?._isInVariation ?? false;

  @override
  int? get currentVariationNodeId {
    final path = _state?._analysisPath;
    if (path == null || path.isEmpty) return null;
    return path.last.id;
  }

  @override
  bool get hasSavedSidelines {
    final state = _state;
    if (state == null) return false;
    for (final roots in state._variationsByPly.values) {
      if (roots.any((r) => !r.isEphemeral)) return true;
    }
    return false;
  }

  @override
  solitaire_script.SolitaireScript? buildSolitaireScript({
    required int fromMainlinePly,
    required bool includeVariations,
  }) {
    final state = _state;
    if (state == null || state._moveHistory.isEmpty) return null;
    return solitaire_script.buildSolitaireScript(
      state._m,
      fromMainlinePly: fromMainlinePly,
      includeVariations: includeVariations,
    );
  }

  @override
  void setSolitaireReveal(SolitaireReveal? reveal) {
    final state = _state;
    if (state == null) return;
    state._m.reveal = reveal;
    // The frontier may have moved behind the cursor (a session starting at
    // the game start while the reader was at move 30): pull the cursor back.
    final frontier = reveal?.mainlinePly;
    if (frontier != null &&
        state._analysisPath.isEmpty &&
        !state._inlineActive &&
        state._mainLineIndex > frontier) {
      state._goToMainLineMove(frontier);
      return;
    }
    state._rebuild();
  }

  /// Jump from the current variation back to the mainline branch point.
  @override
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

  @override
  void addGuessNodeAnnotations(Map<int, String> notes) =>
      _state?._addGuessNodeAnnotations(notes);

  @override
  void addGuessNodeVariations(Map<int, List<String>> wrongByParentId) =>
      _state?._addGuessNodeVariations(wrongByParentId);

  /// Persist wrong solitaire guesses as sideline variations (keyed by 0-based
  /// mainline ply), promoting the live ephemeral nodes so they survive the save.
  @override
  void addGuessVariations(Map<int, List<String>> wrongByPly) =>
      _state?._addGuessVariations(wrongByPly);
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

  /// Open annotated course PGNs as a calm, one-note-at-a-time reader. The
  /// complete movetext remains one click away.
  final bool preferFocusedReading;

  /// Mainline ply restored by a collection host when this game was visited
  /// earlier in the session.
  final int initialMainLineIndex;

  /// Fires once the game has been parsed and is on screen — the moment a
  /// host that drives this widget (solitaire) can rely on its moves.
  final VoidCallback? onGameLoaded;

  /// Force book-PGN formatting for ambiguous short comments. Clear Chessable
  /// markup and long book prose are detected automatically — see
  /// [PgnMovetextView.bookFormatting].
  final bool bookFormatting;

  /// Leave the result out of the header line. Solitaire sets it: "1-0" above
  /// a game you are guessing your way through answers the question before the
  /// first move.
  final bool hideResult;

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
    this.preferFocusedReading = false,
    this.initialMainLineIndex = 0,
    this.onGameLoaded,
    this.bookFormatting = false,
    this.hideResult = false,
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
  /// The game model — single owner of the parsed game, mainline spine,
  /// per-ply sidelines, and cursor. Widget code reads it through the
  /// forwarding getters below (so the renderer call sites and the mixins'
  /// read-only logic stay unchanged) and mutates it only inside the thin
  /// setState wrappers in the part-file mixins.
  final ViewerGameModel _m = ViewerGameModel();

  PgnGame? get _game => _m.game;
  List<PgnNodeData> get _moveHistory => _m.moveHistory;
  int get _mainLineIndex => _m.mainLineIndex;
  Position get _currentPosition => _m.currentPosition;
  Position get _startPosition => _m.startPosition;
  Map<int, List<MoveNode>> get _variationsByPly => _m.variationsByPly;
  int get _activeBranchPly => _m.activeBranchPly;
  List<MoveNode> get _analysisPath => _m.analysisPath;

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

  /// Repaint after the model changed under the widget's feet.
  void _rebuild() {
    if (mounted) setState(() {});
  }

  // Cross-group members: each is implemented in the named part-file mixin.
  void _clearAnalysis(); // move edits
  void _deleteAnalysisNode(int nodeId); // move edits
  void _clearInlineLine(); // navigation
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
  /// Header text with the result in it, and the same text without — both
  /// built once per game so [PgnViewerWidget.hideResult] can be flipped
  /// (entering solitaire) without re-parsing anything.
  String _gameInfo = '';
  String _gameInfoNoResult = '';
  late bool _focusedReading = widget.preferFocusedReading;

  String get _headerText => widget.hideResult ? _gameInfoNoResult : _gameInfo;
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
      unawaited(
        scrollable.position.ensureVisible(
          renderObject,
          alignment: 0.5,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
        ),
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
      // The same game with new annotations on it (an engine pass writing
      // its scores and lines back) is adopted where the reader is; anything
      // else is a different game and starts over.
      if (gameIdChanged || !_adoptAnnotations(widget.pgnText)) {
        if (widget.preferFocusedReading != oldWidget.preferFocusedReading) {
          _focusedReading = widget.preferFocusedReading;
        }
        unawaited(_loadGame());
      }
    } else if (widget.moveNumber != oldWidget.moveNumber ||
        widget.isWhiteToPlay != oldWidget.isWhiteToPlay) {
      _clearAnalysis();
      if (widget.moveNumber != null && widget.isWhiteToPlay != null) {
        _jumpToMove(widget.moveNumber!, widget.isWhiteToPlay!);
      }
    }
  }

  /// Try to take [pgnText]'s annotations onto the loaded game in place.
  /// See [ViewerGameModel.adoptAnnotations].
  bool _adoptAnnotations(String? pgnText) {
    if (pgnText == null || _isLoading || _m.game == null) return false;
    try {
      final adopted = _m.adoptAnnotations(PgnGame.parsePgn(pgnText));
      if (adopted) setState(() {});
      return adopted;
    } catch (_) {
      return false;
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
      if (!mounted) return;

      setState(() {
        _m.load(game);
        _gameInfo = _buildGameInfo(game);
        _gameInfoNoResult = _buildGameInfo(game, includeResult: false);
        _isLoading = false;
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
        } else if (widget.initialMainLineIndex > 0) {
          _goToMainLineMove(widget.initialMainLineIndex);
        }
        widget.onGameLoaded?.call();
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

  Future<String> _findGamePgn(String gameId) => findStoredGamePgn(gameId);

  String _buildGameInfo(PgnGame game, {bool includeResult = true}) {
    final white = (game.headers['White'] ?? '?').trim();
    final black = (game.headers['Black'] ?? '?').trim();
    final event = game.headers['Event'] ?? '';
    final wElo = game.headers['WhiteElo'];
    final bElo = game.headers['BlackElo'];
    final hasElo =
        (wElo != null && wElo.isNotEmpty && wElo != '?') ||
        (bElo != null && bElo.isNotEmpty && bElo != '?');
    final result = (game.headers['Result'] ?? '').trim();
    final gameId = (game.headers['GameId'] ?? '').trim();

    // Book-style PGN detection: no ratings, no real event, and White holds a
    // chapter/theme title rather than a "Lastname, Firstname" player name.
    // These exports put the chapter theme in White and the specific
    // game/exercise in Black, so present them as title + theme subtitle
    // instead of the confusing "Theme vs Player1 - Player2 #3/4".
    final whiteIsTitle = !_isBlankHeader(white) && !_looksLikePlayerName(white);
    final hasBookIdentity =
        widget.bookFormatting ||
        gameId.isNotEmpty ||
        (!_isBlankHeader(white) && white == black);
    if (!hasElo &&
        _isBlankHeader(event) &&
        whiteIsTitle &&
        (result.isEmpty || result == '*') &&
        hasBookIdentity) {
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
    final displayResult = includeResult ? result : '';

    // Build detail line, omitting blank/placeholder parts
    final details = [
      event,
      date,
      displayResult,
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
    final lines = _headerText.split('\n');
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
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              line,
              // bodySmall is already muted (onSurfaceMuted) — dimming it
              // further with alpha would drop below WCAG AA at this 12px size.
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }

  String _focusComment() {
    if (_moveHistory.isEmpty) return '';
    final chunks = <String>[];
    if (_mainLineIndex == 0) {
      chunks.addAll(_moveHistory.first.startingComments ?? const []);
    } else {
      final move = _moveHistory[_mainLineIndex - 1];
      chunks
        ..addAll(move.startingComments ?? const [])
        ..addAll(move.comments ?? const []);
    }
    // Course exporters encode paragraph breaks as repeated spaces. Protect
    // sentence-boundary breaks before the generic PGN cleaner collapses
    // whitespace, then restore them as real paragraphs for the reading card.
    const paragraphMarker = '\uE000';
    final withParagraphs = chunks
        .join(' ')
        .replaceAllMapped(
          RegExp(r'([.!?])\s{2,}(?=[A-Z“])'),
          (m) => '${m[1]}$paragraphMarker',
        );
    return _normalizeCourseSpacing(
      filterDisplayComment(stripEngineTokens(withParagraphs)),
    ).replaceAll(paragraphMarker, '\n\n');
  }

  /// Chessable exports sometimes remove the spaces around numbered moves in
  /// prose (`against1.e4and`, `5...Be7`). Repair that only for display; the
  /// PGN bytes and comment editor remain untouched.
  static String _normalizeCourseSpacing(String text) {
    var result = text.replaceAllMapped(
      RegExp(r'([A-Za-z,;:!?])(\d+\.{1,3})'),
      (m) => '${m[1]} ${m[2]}',
    );
    final numberedSan = RegExp(
      r'(\d+\.{1,3}(?:O-O-O|O-O|(?:[KQRBN][a-h1-8]?x?[a-h][1-8]|[a-h]x[a-h][1-8]|[a-h][1-8])(?:=[QRBN])?)[+#?!]*)(?=[A-Za-z])',
    );
    result = result.replaceAllMapped(numberedSan, (m) => '${m[1]} ');
    result = result.replaceAllMapped(
      RegExp(r'([+#])(?=[KQRBNOa-h])'),
      (m) => '${m[1]} ',
    );
    return result.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  }

  Widget _buildReaderModeSwitch() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      color: AppColors.surfaceElevated,
      child: Row(
        children: [
          const Icon(Icons.menu_book_outlined, size: 17, color: AppColors.info),
          const SizedBox(width: 7),
          const Text(
            'Reading view',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: true,
                icon: Icon(Icons.chrome_reader_mode_outlined, size: 16),
                label: Text('Focus'),
              ),
              ButtonSegment(
                value: false,
                icon: Icon(Icons.account_tree_outlined, size: 16),
                label: Text('Full notation'),
              ),
            ],
            selected: {_focusedReading},
            onSelectionChanged: (selection) {
              setState(() => _focusedReading = selection.first);
            },
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFocusedReader() {
    final atStart = _mainLineIndex == 0;
    final atEnd = _mainLineIndex >= _moveHistory.length;
    final current = atStart ? null : _moveHistory[_mainLineIndex - 1];
    final previous = _mainLineIndex >= 2
        ? _moveHistory[_mainLineIndex - 2]
        : null;
    final coords = current == null
        ? null
        : coordsAtPly(
            ply: _mainLineIndex - 1,
            startFullmoves: _startPosition.fullmoves,
            startWhiteToMove: _startPosition.turn == Side.white,
          );
    final previousCoords = previous == null
        ? null
        : coordsAtPly(
            ply: _mainLineIndex - 2,
            startFullmoves: _startPosition.fullmoves,
            startWhiteToMove: _startPosition.turn == Side.white,
          );
    final comment = _focusComment();

    String moveLabel(PgnNodeData move, ({int moveNumber, bool isWhite}) c) =>
        isNullMoveSan(move.san)
        ? 'Introduction'
        : '${c.moveNumber}${c.isWhite ? '.' : '...'} ${move.san}';

    return ColoredBox(
      color: AppColors.pgnSurface,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: ValueKey('focused-reader-$_mainLineIndex'),
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Center(
                child: ConstrainedBox(
                  // A book-like measure: roughly 60–75 characters for the
                  // bundled Inter face at 16px, instead of spanning the pane.
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          if (previous != null && previousCoords != null)
                            Expanded(
                              child: Text(
                                'Previous  ${moveLabel(previous, previousCoords)}',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: AppTextStyles.monoFamily,
                                  fontSize: 12,
                                  color: AppColors.onSurfaceMuted,
                                ),
                              ),
                            )
                          else
                            const Spacer(),
                          Text(
                            '$_mainLineIndex / ${_moveHistory.length}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.onSurfaceMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (current != null && coords != null)
                        Text(
                          moveLabel(current, coords),
                          style: const TextStyle(
                            fontFamily: AppTextStyles.monoFamily,
                            fontSize: 22,
                            height: 1.25,
                            fontWeight: FontWeight.w700,
                            color: AppColors.pgnMoveCurrentFg,
                          ),
                        )
                      else
                        const Text(
                          'Before the first move',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.fromLTRB(18, 17, 18, 18),
                        decoration: BoxDecoration(
                          color: AppColors.pgnCommentBlockBg,
                          borderRadius: BorderRadius.circular(10),
                          border: const Border(
                            left: BorderSide(color: AppColors.accent, width: 4),
                          ),
                        ),
                        child: Text(
                          comment.isEmpty
                              ? (atStart
                                    ? 'Press → to begin this line.'
                                    : 'No note on this move. Keep stepping through the line.')
                              : comment,
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.65,
                            color: comment.isEmpty
                                ? AppColors.onSurfaceMuted
                                : AppColors.pgnComment,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            decoration: const BoxDecoration(
              color: AppColors.surfaceElevated,
              border: Border(top: BorderSide(color: AppColors.divider)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: atStart ? null : _goBack,
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('Previous move'),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: atEnd ? null : _goForward,
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  label: const Text('Next move'),
                ),
              ],
            ),
          ),
        ],
      ),
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

    if (!_focusedReading) _scheduleScrollCurrentMoveIntoView();

    return Column(
      children: [
        if (_headerText.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(8),
            child: _buildGameHeader(context),
          ),
        if (widget.preferFocusedReading) _buildReaderModeSwitch(),
        Expanded(
          child: _focusedReading
              ? _buildFocusedReader()
              : ColoredBox(
                  // A dedicated ink surface makes the hierarchy in AppColors'
                  // pgn tokens deterministic wherever this reusable viewer sits.
                  color: AppColors.pgnSurface,
                  // SelectionArea lets the user drag-select movetext / comments and
                  // copy with Ctrl+C; move taps still hit the inner GestureDetectors.
                  child: SelectionArea(
                    child: SingleChildScrollView(
                      controller: _movetextScrollController,
                      padding: const EdgeInsets.fromLTRB(12, 10, 14, 18),
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
                        reveal: _m.reveal,
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
