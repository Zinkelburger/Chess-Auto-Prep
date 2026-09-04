/// Movetext rendering for the PGN viewer.
///
/// Renders the mainline + sideline variations + inline/prose comments as a
/// flowing `Wrap` of `Text.rich` / `RichText`, plus the inline comment editor
/// (right-click → Comment). Extracted from `pgn_viewer_widget.dart`
/// as a pure leaf view: it takes the move history, the per-ply variation tree,
/// the current navigation/edit state, and callbacks — it owns no state of its
/// own (the inline editor keeps its own [TextEditingController]).
library;

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
import 'comment_prose_spans.dart';
import 'movetext_primitives.dart' show MoveChip;
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
        parsePvComment,
        stripEngineTokens,
        stripPgnTokens,
        allNagSuffix,
        joinComments,
        kMaxUnevaluatedPlies,
        CommentToken,
        CommentProse,
        CommentMove,
        MoveMetrics,
        RichSegment,
        RichSegmentType,
        kSanCorePattern;

part 'pgn_movetext_prose_scan.dart';
part 'pgn_movetext_comments.dart';
part 'pgn_movetext_eval_notes.dart';
part 'pgn_movetext_variations.dart';

/// Border reserved on every non-highlighted move chip so that highlighting or
/// hovering one never changes its size — which would reflow the whole wrap.
final _kReservedBorder = BoxDecoration(
  borderRadius: BorderRadius.circular(3),
  border: Border.all(color: Colors.transparent, width: 1),
);

/// Hover affordance for a move chip. This replaces the former always-on dotted
/// underline: in movetext *every* token is a move, so a permanent per-move
/// decoration is hundreds of marks carrying zero information.
final _kHoverDecoration = BoxDecoration(
  color: AppColors.pgnMoveHoverBg,
  borderRadius: BorderRadius.circular(3),
  border: Border.all(color: Colors.transparent, width: 1),
);

class PgnMovetextView extends StatefulWidget {
  /// The parsed game (for game-level comments before any move).
  final PgnGame? game;

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

  /// Opt-in book-PGN comment formatting (Chessable/Forward Chess exports):
  /// `@@...@@` rich segments, double-space paragraph breaks, and bordered
  /// comment blocks. Off by default because ordinary PGNs (e.g. Lichess study
  /// exports) use stray double spaces inside prose, which this mode would
  /// misread as paragraph breaks. When off, every comment renders as plain
  /// flowing prose (moves written in the prose stay clickable when legal).
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

  /// Attached to the current mainline move so the host can scroll it into view.
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
    required this.moveHistory,
    required this.variationsByPly,
    required this.mainLineIndex,
    required this.analysisPath,
    required this.editingCommentIndex,
    required this.canEditComments,
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
  /// Ids of branch nodes whose folded deep sidelines the reader has opened.
  /// Keyed by [MoveNode.id], which is stable for the session.
  final Set<int> _expandedBranches = <int>{};

  void _toggleBranch(int id) {
    setState(() {
      if (!_expandedBranches.remove(id)) _expandedBranches.add(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = widget;
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
    // use their own styles via [PgnTextStyles]. Weight-free so prose spans
    // don't inherit the mainline's semibold.
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

    /// The engine's line from before a marked move. Its own row, because
    /// there are only ever a handful of these in a game — unlike the per-ply
    /// scores they replace, which is the whole reason those are gone.
    void emitBestLine(_EvalNote note, int moveIndex) {
      final spans = _bestLineSpans(view, note.pv, moveIndex);
      if (spans.isEmpty) return;
      emitFullWidthRow(
        RichText(
          text: TextSpan(style: PgnTextStyles.commentAt(0), children: spans),
        ),
        vertical: 2,
      );
    }

    /// Emit every sideline at [ply] as one cohesive block. The breathing room
    /// goes *around* the group, not between its rows — uniform per-row padding
    /// is what turns a page of sidelines into an even gray mass with no
    /// entry points.
    void emitVariationsAtPly(int ply) {
      final reveal = view.reveal;
      final rows = _buildVariationRowsAtPly(
        view,
        ply,
        nodeVisible: reveal == null
            ? null
            : (node) => reveal.isNodeVisible(node, ply),
        expandedBranches: _expandedBranches,
        onToggleBranch: _toggleBranch,
      );
      if (rows.isEmpty) return;
      emitFullWidthRow(
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
        vertical: 6,
      );
    }

    // Board after each mainline half-move (prefix[k] = position after k moves),
    // used to legality-check moves mentioned inside prose comments.
    final prefix = _buildPrefixPositions(view);

    // On a game an engine has been over, the per-ply `[%eval]` comments are
    // not rendered at all — only the moves whose score actually moved get a
    // mark. A game with no mistakes in it still hides them, which is why this
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

    // Variations at ply 0 (before any move)
    final varsAtZero = view.variationsByPly[0];
    if (varsAtZero != null && varsAtZero.isNotEmpty) {
      emitVariationsAtPly(0);
    }

    for (int i = 0; i < view.moveHistory.length; i++) {
      // Solitaire mode: stop rendering at the revealed boundary
      if (view.reveal != null && !view.reveal!.isMainlineVisible(i)) break;

      final moveData = view.moveHistory[i];
      final san = moveData.san;

      // Render startingComments (comments before the move)
      if (moveData.startingComments != null &&
          moveData.startingComments!.isNotEmpty) {
        for (final sc in moveData.startingComments!) {
          emitComment(sc, anchorPos: _posAt(prefix, i), anchorPly: i);
        }
      }

      // Skip rendering null-move SAN (ChessBase `--` / `Z0`) but still show
      // comments and any sidelines that branch after the pass.
      if (isNullMoveSan(san)) {
        for (final c in moveData.comments ?? const <String>[]) {
          if (machineAnnotated && _isEvalOnlyComment(c)) continue;
          emitComment(c);
        }
        final ply = i + 1;
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
          i == view.mainLineIndex - 1 && view.analysisPath.isEmpty;

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
      final nagSuffix = allNagSuffix(moveData.nags);

      final currentDecoration = BoxDecoration(
        color: AppColors.pgnMoveCurrentBg,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: AppColors.pgnMoveCurrent, width: 1),
      );

      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: MoveChip(
            san: san,
            nagSuffix: nagSuffix,
            sanStyle: moveStyle,
            nagStyle: moveStyle.copyWith(
              fontSize: PgnTextStyles.sizeAt(0) - 1,
              fontWeight: FontWeight.bold,
            ),
            decoration: isCurrentMove ? currentDecoration : _kReservedBorder,
            hoverDecoration: isCurrentMove
                ? currentDecoration
                : _kHoverDecoration,
            containerKey: isCurrentMove ? view.currentMoveKey : null,
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
        // The mark on a move that cost something rides inline, right after the
        // move, so the movetext keeps flowing.
        final note = evalNotes[i];
        if (note != null) spans.addAll(_evalNoteSpans(note));

        // All of them. A PGN may attach several `{}` blocks to one move (a
        // Lichess study export splits prose from a `[%cal]` block, book PGNs
        // split a header from its text); showing only the first quietly hid
        // whichever half came second. The exception is a bare engine score on
        // an analyzed game: [evalNotes] already says everything it had to say.
        for (final c in moveData.comments ?? const <String>[]) {
          if (machineAnnotated && _isEvalOnlyComment(c)) continue;
          emitComment(c, anchorPos: _posAt(prefix, i + 1), anchorPly: i + 1);
        }

        if (note != null) emitBestLine(note, i);
      }

      // Variations branch *after* the move at index i (ply = i + 1). In
      // solitaire, only ephemeral attempts show at the un-guessed frontier.
      final ply = i + 1;
      final varsHere = view.variationsByPly[ply];
      if (varsHere != null && varsHere.isNotEmpty) {
        emitVariationsAtPly(ply);
      }

      if (!isWhiteTurn) moveNumber++;
      isWhiteTurn = !isWhiteTurn;
    }

    // NOTE: variations branching after the final move are already rendered by
    // the loop above (ply = i + 1 reaches moveHistory.length on the last move).
    // Do NOT re-render them here or they appear twice.

    flushSpans();

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}
