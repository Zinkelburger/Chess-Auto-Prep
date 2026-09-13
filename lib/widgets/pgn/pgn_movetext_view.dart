/// Movetext rendering for the PGN viewer.
///
/// Renders mainline and sideline moves as a continuous annotated document.
/// The host owns board navigation; this view owns disclosure state and keeps
/// every explanation in its original place in the PGN.
library;

import '../../utils/pgn_nags.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../core/pgn/mainline_positions.dart';
import '../../core/pgn/solitaire_reveal.dart';
import '../../models/move_tree.dart';
import '../../services/game_analysis_controller.dart'
    show MoveClassification, classifyMove, cpToWinningChance, initialWinChance;
import '../../theme/app_colors.dart';
import '../../theme/pgn_text_styles.dart';
import 'comment_editor.dart';
import 'comment_diagram.dart';
import '../../utils/course_comment_spacing.dart';
import '../../utils/prose_comment_parser.dart';
import 'pgn_reading_pane.dart';
import 'pgn_reading_passage.dart';
import 'movetext_primitives.dart' show MoveChip, PgnMoveDecorations;
import '../../utils/chess_utils.dart'
    show coordsAtPly, formatEvalDisplay, isNullMoveSan;
import '../../utils/pgn_comment_utils.dart'
    show
        commentProse,
        filterDisplayComment,
        hasChessableFormatting,
        parseRichComment,
        parseCommentTokens,
        parseEvalComment,
        parseMaiaComment,
        parsePvComment,
        stripEngineTokens,
        stripPgnTokens,
        joinComments,
        kMaxUnevaluatedPlies,
        CommentToken,
        CommentProse,
        CommentDiagram,
        CommentMove,
        MoveMetrics,
        RichSegment,
        RichSegmentType,
        kSanCorePattern;

part 'pgn_movetext_prose_scan.dart';
part 'pgn_movetext_comments.dart';
part 'pgn_movetext_eval_notes.dart';
part 'pgn_movetext_variations.dart';

// Also used by the prose-preview chips in the comment renderer.
const _kReservedBorder = PgnMoveDecorations.idle;
final _kHoverDecoration = PgnMoveDecorations.hover;

class PgnMovetextView extends StatefulWidget {
  /// The parsed game (for game-level comments before any move).
  final PgnGame? game;
  final PgnReadingBranch? readingScope;
  final bool expandAll;

  /// Mainline moves in display order.
  final List<PgnNodeData> moveHistory;

  /// ply (0-based mainline index) -> root variation nodes branching there.
  final Map<int, List<MoveNode>> variationsByPly;

  /// 1-based index of the current mainline position (0 = start).
  final int mainLineIndex;

  /// Path into the current variation (empty = on the mainline).
  final List<MoveNode> analysisPath;

  /// Mainline index whose comment is being edited inline, or null.
  final int? editingCommentIndex;

  /// Whether comments can be edited (click a move to edit its comment).
  final bool canEditComments;

  /// Show every source branch separately while editing its annotations.
  final bool editMode;

  /// Force book-PGN comment formatting for ambiguous source material.
  /// Recognizable Chessable/Forward Chess markup and long multi-paragraph
  /// comments are detected automatically; this flag is only needed when a
  /// short export uses double spaces as paragraph breaks without markers.
  final bool bookFormatting;

  /// Starting fullmove number from the FEN (defaults to 1).
  final int startingMoveNumber;

  /// Whether it's white's turn at the start (from the FEN; defaults to true).
  final bool startingWhiteTurn;

  /// The game's starting position. When provided, moves written inside prose
  /// comments are detected and made clickable if they are *legal* from the
  /// comment's anchor position (played via [onPlayInlineLine]).
  final Position? startPosition;

  final ValueChanged<int> onMainLineMoveClicked;
  final void Function(int moveIndex, Offset globalPosition)
  onShowMoveContextMenu;
  final void Function(int moveIndex, String text) onSaveComment;
  final VoidCallback onCancelEditingComment;
  final void Function(MoveNode node, int branchPly) onGoToAnalysisNode;

  /// Right-click on a variation node (copy line / add to study / delete menu).
  final void Function(MoveNode node, int branchPly, Offset globalPosition)?
  onShowVariationContextMenu;

  /// What a running solitaire session lets the reader see: mainline moves
  /// past its frontier and sidelines it has not reached are not rendered.
  /// Null when no session is running.
  final SolitaireReveal? reveal;

  /// Attached to the current move or annotated passage, including sidelines.
  final Key? currentMoveKey;

  /// Preview an inline analysis line embedded in a comment: navigate the board
  /// through the run starting at [moveNumber]/[isWhite] and stop at
  /// [clickedIndex]. [sans] is the run's full move list. This does not modify
  /// the move tree — it just walks the board so the comment keeps its rendering.
  final void Function(
    int moveNumber,
    bool isWhite,
    List<String> sans,
    int clickedIndex, {
    String? anchorFen,
  })?
  onPlayInlineLine;

  /// The inline line currently being previewed (for in-place highlighting), or
  /// null. Matched against each rendered run by its first move + move list.
  final ({
    int firstMoveNumber,
    bool firstIsWhite,
    List<String> sans,
    int cursor,
    String? anchorFen,
  })?
  activeInlineLine;

  const PgnMovetextView({
    super.key,
    required this.game,
    this.readingScope,
    this.expandAll = false,
    required this.moveHistory,
    required this.variationsByPly,
    required this.mainLineIndex,
    required this.analysisPath,
    required this.editingCommentIndex,
    required this.canEditComments,
    this.editMode = false,
    this.bookFormatting = false,
    this.startingMoveNumber = 1,
    this.startingWhiteTurn = true,
    this.startPosition,
    required this.onMainLineMoveClicked,
    required this.onShowMoveContextMenu,
    required this.onSaveComment,
    required this.onCancelEditingComment,
    required this.onGoToAnalysisNode,
    this.onShowVariationContextMenu,
    this.reveal,
    this.currentMoveKey,
    this.onPlayInlineLine,
    this.activeInlineLine,
  });

  @override
  State<PgnMovetextView> createState() => _PgnMovetextViewState();
}

class _PgnMovetextViewState extends State<PgnMovetextView> {
  final Map<int, bool> _branchVisibility = {};

  void _toggleBranch(int id) {
    if (!mounted) return;
    setState(() => _branchVisibility[id] = !(_branchVisibility[id] ?? true));
  }

  @override
  void didUpdateWidget(PgnMovetextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expandAll != widget.expandAll ||
        oldWidget.game != widget.game) {
      _branchVisibility.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = widget;
    if (view.readingScope case final scope?) {
      return _buildVariationDocument(
        view,
        scope.root,
        ply: scope.ply,
        branchPly: scope.branchPly,
        depth: 0,
        branchVisibility: _branchVisibility,
        onToggleBranch: _toggleBranch,
        nodeVisible: view.reveal == null
            ? null
            : (node) => view.reveal!.isNodeVisible(node, scope.branchPly),
      );
    }
    if (view.moveHistory.isEmpty &&
        view.variationsByPly.isEmpty &&
        (view.game == null || view.game!.comments.isEmpty)) {
      return const SizedBox();
    }

    final children = <Widget>[];
    final spans = <InlineSpan>[];
    var moveNumber = view.startingMoveNumber;
    var isWhiteTurn = view.startingWhiteTurn;
    // After a comment/variation/editor breaks the mainline Wrap run, the next
    // Black move must show `N...` (same as the start-of-game Black case).
    var forceBlackEllipsis = false;

    // Root style for RichText runs of mainline moves; comments/variations
    // use their own styles via [PgnTextStyles].
    final baseStyle = PgnTextStyles.rowRootAt(0);

    void flushSpans() {
      if (spans.isNotEmpty) {
        children.add(
          RichText(
            text: TextSpan(style: baseStyle, children: List.of(spans)),
          ),
        );
        spans.clear();
        forceBlackEllipsis = true;
      }
    }

    /// Put [child] on its own full-width row so Wrap cannot glue it into
    /// neighboring move spans (anti-spaghetti for comments / variations).
    void emitFullWidthRow(Widget child, {double vertical = 4}) {
      flushSpans();
      forceBlackEllipsis = true;
      children.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: vertical),
          child: SizedBox(width: double.infinity, child: child),
        ),
      );
    }

    void emitComment(String raw, {Position? anchorPos, int anchorPly = 0}) {
      // Measured facts first, on their own row: a generated line annotates
      // every move, and interleaving that with prose would bury both.
      final metrics = _metricsSpans(raw);
      if (metrics.isNotEmpty) {
        emitFullWidthRow(
          RichText(text: TextSpan(children: List.of(metrics))),
          vertical: 2,
        );
      }
      final rendered = _renderComment(
        view,
        raw,
        anchorPos: anchorPos,
        anchorPly: anchorPly,
      );
      if (rendered.block != null) {
        // Blocks already carry their own vertical margin — don't double it.
        emitFullWidthRow(rendered.block!, vertical: 0);
      } else if (rendered.spans.isNotEmpty) {
        emitFullWidthRow(
          RichText(
            text: TextSpan(
              style: PgnTextStyles.commentAt(0),
              children: List.of(rendered.spans),
            ),
          ),
        );
      }
    }

    final decoratedRoots = <int>{};

    /// Keep the verdict and suggested line together, inset from the game and
    /// with enough space below to clearly resume the played moves.
    void emitEvalNote(_EvalNote note, int moveIndex) {
      final root = note.pv.isEmpty
          ? null
          : view.variationsByPly[moveIndex]
                ?.where(
                  (node) =>
                      node.san == note.pv.first &&
                      (view.reveal?.isNodeVisible(node, moveIndex) ?? true),
                )
                .firstOrNull;
      if (root != null) decoratedRoots.add(root.id);
      emitFullWidthRow(
        Container(
          margin: const EdgeInsets.fromLTRB(20, 6, 0, 14),
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: nagColor(
                  note.classification.nag ?? 0,
                ).withValues(alpha: 0.55),
                width: 2,
              ),
            ),
          ),
          child: Column(
            key: ValueKey('pgn-analysis-line-$moveIndex'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RichText(
                text: TextSpan(
                  style: PgnTextStyles.commentAt(0),
                  children: _evalNoteSpans(note),
                ),
              ),
              if (root != null)
                _buildVariationDocument(
                  view,
                  root,
                  ply: moveIndex,
                  branchPly: moveIndex,
                  depth: 1,
                  branchVisibility: _branchVisibility,
                  onToggleBranch: _toggleBranch,
                  leadingLabel: 'Best: ',
                  nodeVisible: view.reveal == null
                      ? null
                      : (node) => view.reveal!.isNodeVisible(node, moveIndex),
                ),
            ],
          ),
        ),
        vertical: 0,
      );
    }

    /// Emit every sideline at [ply] as one cohesive block. The breathing room
    /// goes *around* the group, not between its rows — uniform per-row padding
    /// is what turns a page of sidelines into an even gray mass with no
    /// entry points.
    void emitVariationsAtPly(int ply) {
      final reveal = view.reveal;
      final inline = _buildInlineVariationAtPly(
        view,
        ply,
        nodeVisible: (node) =>
            !decoratedRoots.contains(node.id) &&
            (reveal?.isNodeVisible(node, ply) ?? true),
      );
      if (inline != null) {
        spans.addAll(inline);
        return;
      }
      final rows = _buildVariationRowsAtPly(
        view,
        ply,
        nodeVisible: (node) =>
            !decoratedRoots.contains(node.id) &&
            (reveal?.isNodeVisible(node, ply) ?? true),
        branchVisibility: _branchVisibility,
        onToggleBranch: _toggleBranch,
      );
      if (rows.isEmpty) return;
      emitFullWidthRow(
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
        vertical: 0,
      );
    }

    // Board after each mainline half-move (prefix[k] = position after k moves),
    // used to legality-check moves mentioned inside prose comments.
    final prefix = _buildPrefixPositions(view);

    // On a game an engine has been over, the per-ply `[%eval]` comments are
    // not rendered at all — every classified move gets a mark, including
    // interesting moves identified by Maia. A game with no mistakes in it still hides them, which is why this
    // is a separate flag and not "are there any notes".
    final machineAnnotated = _isMachineAnnotated(view.moveHistory);
    final evalNotes = machineAnnotated
        ? _buildEvalNotes(view)
        : const <int, _EvalNote>{};

    // Game-level comments (before any moves) — common in book PGNs
    if (view.game != null && view.game!.comments.isNotEmpty) {
      for (final comment in view.game!.comments) {
        emitComment(comment, anchorPos: _posAt(prefix, 0), anchorPly: 0);
      }
    }

    for (int i = 0; i < view.moveHistory.length; i++) {
      // Solitaire mode: stop rendering at the revealed boundary
      if (view.reveal != null && !view.reveal!.isMainlineVisible(i)) break;

      final moveData = view.moveHistory[i];
      final san = moveData.san;
      final annotated = (moveData.comments ?? const <String>[]).any(
        (c) => filterDisplayComment(c).isNotEmpty,
      );
      if (annotated) flushSpans();

      // Render startingComments (comments before the move)
      if (moveData.startingComments != null &&
          moveData.startingComments!.isNotEmpty) {
        for (final sc in moveData.startingComments!) {
          emitComment(sc, anchorPos: _posAt(prefix, i), anchorPly: i);
        }
      }

      final passageStart = children.length;

      // Skip rendering null-move SAN (ChessBase `--` / `Z0`) but still show
      // comments and any sidelines that branch after the pass.
      if (isNullMoveSan(san)) {
        for (final c in moveData.comments ?? const <String>[]) {
          if (machineAnnotated && _isEvalOnlyComment(c)) continue;
          emitComment(c, anchorPos: _posAt(prefix, i), anchorPly: i);
        }
        final ply = i;
        final varsHere = view.variationsByPly[ply];
        if (varsHere != null && varsHere.isNotEmpty) {
          emitVariationsAtPly(ply);
        }
        if (!isWhiteTurn) moveNumber++;
        isWhiteTurn = !isWhiteTurn;
        continue;
      }

      if (isWhiteTurn) {
        spans.add(
          TextSpan(text: '$moveNumber. ', style: PgnTextStyles.moveNumberAt(0)),
        );
        forceBlackEllipsis = false;
      } else if (forceBlackEllipsis || (i == 0 && !view.startingWhiteTurn)) {
        // Black after a line break (comment/variation/editor) or game start.
        spans.add(
          TextSpan(
            text: '$moveNumber... ',
            style: PgnTextStyles.moveNumberAt(0),
          ),
        );
        forceBlackEllipsis = false;
      }

      final isCurrentMove =
          i == view.mainLineIndex - 1 &&
          view.analysisPath.isEmpty &&
          view.activeInlineLine == null;

      // SAN styling is independent of NAGs and of whether a sideline exists —
      // structure (own-row, indented variations) marks branches, not a hue.
      // The current move keeps the mainline's weight and size; only the pill
      // changes, so navigating never reflows the wrapped movetext.
      final moveStyle = isCurrentMove
          ? PgnTextStyles.moveAt(0).copyWith(color: AppColors.pgnMoveCurrentFg)
          : PgnTextStyles.moveAt(0);

      // Build SAN + NAG text (always shown — annotations survive view mode).
      // Every NAG, not just the six editable quality glyphs: `⩲`, `∞`, `→` and
      // friends are the annotator's whole verdict on the position.
      // Cached games may predate persisted quality NAGs. Show the same
      // symbols immediately from their scores, without rewriting on read.
      final nags =
          evalNotes[i]?.classification.annotateNags(moveData.nags) ??
          moveData.nags;
      final nagSuffix = allNagSuffix(nags);

      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: MoveChip(
            san: san,
            nagSuffix: nagSuffix,
            sanStyle: moveStyle,
            nagStyle: PgnTextStyles.nagAt(0, moveStyle: moveStyle, nags: nags),
            decoration: PgnMoveDecorations.resolve(selected: isCurrentMove),
            hoverDecoration: PgnMoveDecorations.resolve(
              selected: isCurrentMove,
              hovered: true,
            ),
            containerKey: isCurrentMove && !annotated
                ? view.currentMoveKey
                : null,
            behavior: HitTestBehavior.opaque,
            onTap: () => view.onMainLineMoveClicked(i),
            onSecondaryTapDown: (details) =>
                view.onShowMoveContextMenu(i, details.globalPosition),
          ),
        ),
      );

      spans.add(const TextSpan(text: ' '));

      // Inline comment editor
      if (view.editingCommentIndex == i) {
        flushSpans();
        forceBlackEllipsis = true;
        children.add(
          PgnCommentEditor(
            initialText: commentProse(_rawComment(moveData)),
            onSave: (text) => view.onSaveComment(i, text),
            onCancel: view.onCancelEditingComment,
          ),
        );
      } else {
        final note = evalNotes[i];

        // All of them. A PGN may attach several `{}` blocks to one move (a
        // Lichess study export splits prose from a `[%cal]` block, book PGNs
        // split a header from its text); showing only the first quietly hid
        // whichever half came second. The exception is a bare engine score on
        // an analyzed game: [evalNotes] already says everything it had to say.
        for (final c in moveData.comments ?? const <String>[]) {
          if (machineAnnotated && _isEvalOnlyComment(c)) continue;
          emitComment(c, anchorPos: _posAt(prefix, i + 1), anchorPly: i + 1);
        }

        if (note != null) emitEvalNote(note, i);
      }

      if (annotated) {
        flushSpans();
        final passage = children.sublist(passageStart);
        children.removeRange(passageStart, children.length);
        children.add(
          PgnReadingPassage(
            key: isCurrentMove ? view.currentMoveKey : null,
            active: isCurrentMove,
            children: passage,
          ),
        );
      }

      // RAVs at i are alternatives to the move just read, so its explanation
      // comes first (including opening comments before root alternatives).
      emitVariationsAtPly(i);

      if (!isWhiteTurn) moveNumber++;
      isWhiteTurn = !isWhiteTurn;
    }

    // Continuations added beyond the spine, and revealed solitaire attempts
    // at an unplayed frontier, still need a place after the last visible move.
    final frontier =
        view.reveal?.mainlinePly.clamp(0, view.moveHistory.length) ??
        view.moveHistory.length;
    emitVariationsAtPly(frontier);

    flushSpans();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
