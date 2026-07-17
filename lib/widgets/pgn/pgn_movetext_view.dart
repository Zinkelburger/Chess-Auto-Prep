/// Movetext rendering for the PGN viewer.
///
/// Renders the mainline + sideline variations + inline/prose comments as a
/// flowing `Wrap` of `RichText`, plus the inline comment editor
/// (right-click → Comment). Extracted from `pgn_viewer_widget.dart`
/// as a pure leaf view: it takes the move history, the per-ply variation tree,
/// the current navigation/edit state, and callbacks — it owns no state of its
/// own (the inline editor keeps its own [TextEditingController]).
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../models/move_tree.dart';
import '../../theme/app_colors.dart';
import '../../theme/pgn_text_styles.dart';
import 'comment_editor.dart';
import 'comment_prose_spans.dart';
import '../../utils/chess_utils.dart' show coordsAtPly;
import '../../utils/pgn_comment_utils.dart'
    show
        filterDisplayComment,
        hasChessableFormatting,
        parseRichComment,
        parseCommentTokens,
        stripEngineTokens,
        CommentToken,
        CommentProse,
        CommentMove,
        RichSegment,
        RichSegmentType,
        kSanCorePattern,
        nagSymbol;

part 'pgn_movetext_prose_scan.dart';
part 'pgn_movetext_comments.dart';
part 'pgn_movetext_variations.dart';

class PgnMovetextView extends StatelessWidget {
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

  /// When non-null, moves at index >= revealedPly are hidden (solitaire mode).
  final int? revealedPly;

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
    this.revealedPly,
    this.currentMoveKey,
    this.onPlayInlineLine,
    this.activeInlineLine,
  });

  @override
  Widget build(BuildContext context) {
    if (moveHistory.isEmpty &&
        variationsByPly.isEmpty &&
        (game == null || game!.comments.isEmpty)) {
      return const SizedBox();
    }

    final children = <Widget>[];
    final spans = <InlineSpan>[];
    var moveNumber = startingMoveNumber;
    var isWhiteTurn = startingWhiteTurn;
    // After a comment/variation/editor breaks the mainline Wrap run, the next
    // Black move must show `N...` (same as the start-of-game Black case).
    var forceBlackEllipsis = false;

    // Root style for RichText runs of mainline moves; comments/variations
    // use their own styles via [PgnTextStyles].
    const baseStyle = PgnTextStyles.move;

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
      final rendered = _renderComment(
        this,
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
              style: PgnTextStyles.comment,
              children: List.of(rendered.spans),
            ),
          ),
        );
      }
    }

    void emitVariationsAtPly(int ply, {bool ephemeralOnly = false}) {
      final rows = _buildVariationRowsAtPly(
        this,
        ply,
        ephemeralOnly: ephemeralOnly,
      );
      for (final row in rows) {
        emitFullWidthRow(row, vertical: 2);
      }
    }

    // Board after each mainline half-move (prefix[k] = position after k moves),
    // used to legality-check moves mentioned inside prose comments.
    final prefix = _buildPrefixPositions(this);

    // Game-level comments (before any moves) — common in book PGNs
    if (game != null && game!.comments.isNotEmpty) {
      for (final comment in game!.comments) {
        emitComment(comment, anchorPos: _posAt(prefix, 0), anchorPly: 0);
      }
    }

    // Variations at ply 0 (before any move)
    final varsAtZero = variationsByPly[0];
    if (varsAtZero != null && varsAtZero.isNotEmpty) {
      emitVariationsAtPly(
        0,
        ephemeralOnly: revealedPly != null && revealedPly! <= 0,
      );
    }

    for (int i = 0; i < moveHistory.length; i++) {
      // Solitaire mode: stop rendering at the revealed boundary
      if (revealedPly != null && i >= revealedPly!) break;

      final moveData = moveHistory[i];
      final san = moveData.san;

      // Render startingComments (comments before the move)
      if (moveData.startingComments != null &&
          moveData.startingComments!.isNotEmpty) {
        for (final sc in moveData.startingComments!) {
          emitComment(sc, anchorPos: _posAt(prefix, i), anchorPly: i);
        }
      }

      // Skip rendering null-move SAN but still show its comments
      if (san == '--') {
        if (moveData.comments != null && moveData.comments!.isNotEmpty) {
          emitComment(moveData.comments!.first);
        }
        if (!isWhiteTurn) moveNumber++;
        isWhiteTurn = !isWhiteTurn;
        continue;
      }

      if (isWhiteTurn) {
        spans.add(
          TextSpan(text: '$moveNumber. ', style: PgnTextStyles.moveNumber),
        );
        forceBlackEllipsis = false;
      } else if (forceBlackEllipsis || (i == 0 && !startingWhiteTurn)) {
        // Black after a line break (comment/variation/editor) or game start.
        spans.add(
          TextSpan(text: '$moveNumber... ', style: PgnTextStyles.moveNumber),
        );
        forceBlackEllipsis = false;
      }

      final isCurrentMove = i == mainLineIndex - 1 && analysisPath.isEmpty;

      // SAN color is independent of NAGs and of whether a sideline exists —
      // structure (own-row variations) marks branches, not a separate hue.
      final moveStyle = isCurrentMove
          ? PgnTextStyles.currentMove
          : PgnTextStyles.move;

      // Build SAN + NAG text (always shown — annotations survive view mode)
      final nagSuffix = (moveData.nags != null && moveData.nags!.isNotEmpty)
          ? moveData.nags!.where((n) => n >= 1 && n <= 6).map(nagSymbol).join()
          : '';

      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onMainLineMoveClicked(i),
            onSecondaryTapDown: (details) =>
                onShowMoveContextMenu(i, details.globalPosition),
            child: Container(
              key: isCurrentMove ? currentMoveKey : null,
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              decoration: BoxDecoration(
                color: isCurrentMove ? AppColors.pgnMoveCurrentBg : null,
                borderRadius: BorderRadius.circular(3),
                // Always reserve the 1px border so highlighting a move never
                // resizes it (which would reflow wrapped variation lines).
                border: isCurrentMove
                    ? Border.all(color: AppColors.pgnMoveCurrent, width: 1)
                    : Border.all(color: Colors.transparent, width: 1),
              ),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: san,
                      style: moveStyle.copyWith(
                        decoration: isCurrentMove
                            ? null
                            : TextDecoration.underline,
                        decorationColor: AppColors.onSurfaceMuted.withValues(
                          alpha: 0.5,
                        ),
                        decorationStyle: TextDecorationStyle.dotted,
                      ),
                    ),
                    if (nagSuffix.isNotEmpty)
                      TextSpan(
                        text: nagSuffix,
                        style: moveStyle.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      spans.add(const TextSpan(text: ' '));

      // Inline comment editor
      if (editingCommentIndex == i) {
        flushSpans();
        forceBlackEllipsis = true;
        children.add(
          PgnCommentEditor(
            initialText: _rawComment(moveData),
            onSave: (text) => onSaveComment(i, text),
            onCancel: onCancelEditingComment,
          ),
        );
      } else if (moveData.comments != null && moveData.comments!.isNotEmpty) {
        emitComment(
          moveData.comments!.first,
          anchorPos: _posAt(prefix, i + 1),
          anchorPly: i + 1,
        );
      }

      // Variations branch *after* the move at index i (ply = i + 1). In
      // solitaire, only ephemeral attempts show at the un-guessed frontier.
      final ply = i + 1;
      final varsHere = variationsByPly[ply];
      if (varsHere != null && varsHere.isNotEmpty) {
        emitVariationsAtPly(
          ply,
          ephemeralOnly: revealedPly != null && ply >= revealedPly!,
        );
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
