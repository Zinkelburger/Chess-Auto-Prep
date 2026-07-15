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

  /// A bare SAN move core (no move number, check/annotation glyphs), used to
  /// pre-filter prose words before the (more expensive) legality check.
  static final RegExp _sanCoreRe = RegExp('^$kSanCorePattern\$');

  // Prose-word tokenizers for [_extractLegalSan], hoisted so each prose word
  // doesn't recompile them.
  static final RegExp _leadBracketRe = RegExp(r'^[(\["]+');
  static final RegExp _trailPunctRe = RegExp(r'[)\]",;.!?]+$');
  static final RegExp _moveNumberPrefixRe = RegExp(r'^\d+\.{1,3}');
  static final RegExp _ellipsisPrefixRe = RegExp(r'^\.{2,3}');
  static final RegExp _glyphSuffixRe = RegExp(r'[!?+#]+$');

  static String _rawComment(PgnNodeData moveData) {
    if (moveData.comments == null || moveData.comments!.isEmpty) return '';
    return moveData.comments!.first;
  }

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

    // No fontFamily here: every span that needs monospace (move numbers,
    // moves, brackets) sets it explicitly, so leaving the root proportional
    // lets prose comment spans (which set no family) read as prose, not code.
    const baseStyle = TextStyle(fontSize: 14, color: AppColors.pgnMove);

    void flushSpans() {
      if (spans.isNotEmpty) {
        children.add(
          RichText(
            text: TextSpan(style: baseStyle, children: List.of(spans)),
          ),
        );
        spans.clear();
      }
    }

    // Board after each mainline half-move (prefix[k] = position after k moves),
    // used to legality-check moves mentioned inside prose comments.
    final prefix = _buildPrefixPositions();

    // Game-level comments (before any moves) — common in book PGNs
    if (game != null && game!.comments.isNotEmpty) {
      for (final comment in game!.comments) {
        final rendered = _renderComment(
          comment,
          anchorPos: _posAt(prefix, 0),
          anchorPly: 0,
        );
        if (rendered.block != null) {
          flushSpans();
          children.add(rendered.block!);
        } else if (rendered.spans.isNotEmpty) {
          spans.addAll(rendered.spans);
        }
      }
    }

    // Variations at ply 0 (before any move)
    final varsAtZero = variationsByPly[0];
    if (varsAtZero != null && varsAtZero.isNotEmpty) {
      spans.addAll(
        _buildVariationSpansAtPly(
          0,
          ephemeralOnly: revealedPly != null && revealedPly! <= 0,
        ),
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
          final rendered = _renderComment(
            sc,
            anchorPos: _posAt(prefix, i),
            anchorPly: i,
          );
          if (rendered.block != null) {
            flushSpans();
            children.add(rendered.block!);
          } else if (rendered.spans.isNotEmpty) {
            spans.addAll(rendered.spans);
          }
        }
      }

      // Skip rendering null-move SAN but still show its comments
      if (san == '--') {
        if (moveData.comments != null && moveData.comments!.isNotEmpty) {
          final raw = moveData.comments!.first;
          final rendered = _renderComment(raw);
          if (rendered.block != null) {
            flushSpans();
            children.add(rendered.block!);
          } else if (rendered.spans.isNotEmpty) {
            spans.addAll(rendered.spans);
          }
        }
        if (!isWhiteTurn) moveNumber++;
        isWhiteTurn = !isWhiteTurn;
        continue;
      }

      if (isWhiteTurn) {
        spans.add(
          TextSpan(
            text: '$moveNumber. ',
            style: const TextStyle(
              color: AppColors.pgnMoveNumber,
              fontFamily: 'monospace',
            ),
          ),
        );
      } else if (i == 0 && !startingWhiteTurn) {
        // First move is Black's (game starts from a FEN with Black to move)
        spans.add(
          TextSpan(
            text: '$moveNumber... ',
            style: const TextStyle(
              color: AppColors.pgnMoveNumber,
              fontFamily: 'monospace',
            ),
          ),
        );
      }

      final isCurrentMove = i == mainLineIndex - 1 && analysisPath.isEmpty;
      final hasBranch = variationsByPly.containsKey(i + 1);

      // Move color is independent of NAGs: annotation glyphs (!, ?, !?) render
      // in the same color as the move text, never tinted a separate color.
      final moveColor = isCurrentMove
          ? AppColors.pgnMoveCurrentFg
          : (hasBranch ? AppColors.lichessDb : AppColors.info);

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
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        color: moveColor,
                        fontWeight: FontWeight.normal,
                        decoration: isCurrentMove
                            ? null
                            : TextDecoration.underline,
                        decorationColor: AppColors.onSurfaceDim.withValues(
                          alpha: 0.45,
                        ),
                        decorationStyle: TextDecorationStyle.dotted,
                      ),
                    ),
                    if (nagSuffix.isNotEmpty)
                      TextSpan(
                        text: nagSuffix,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: moveColor,
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
        children.add(
          PgnCommentEditor(
            initialText: _rawComment(moveData),
            onSave: (text) => onSaveComment(i, text),
            onCancel: onCancelEditingComment,
          ),
        );
      } else if (moveData.comments != null && moveData.comments!.isNotEmpty) {
        final raw = moveData.comments!.first;
        final rendered = _renderComment(
          raw,
          anchorPos: _posAt(prefix, i + 1),
          anchorPly: i + 1,
        );
        if (rendered.block != null) {
          flushSpans();
          children.add(rendered.block!);
        } else if (rendered.spans.isNotEmpty) {
          spans.addAll(rendered.spans);
        }
      }

      // Render variations at this ply (ply = i+1 because variations branch
      // *after* the move at index i has been played). In solitaire, source
      // variations at the un-guessed frontier would spoil the position, so
      // only the user's own (ephemeral) attempts show there.
      final ply = i + 1;
      final varsHere = variationsByPly[ply];
      if (varsHere != null && varsHere.isNotEmpty) {
        spans.addAll(
          _buildVariationSpansAtPly(
            ply,
            ephemeralOnly: revealedPly != null && ply >= revealedPly!,
          ),
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

  /// Render a comment as plain flowing prose: engine tokens stripped, all
  /// whitespace collapsed, no paragraph or block structure. Moves written in
  /// the prose stay clickable when they are legal from the anchor position.
  List<InlineSpan> _plainCommentSpans(
    String raw, {
    Position? anchorPos,
    int anchorPly = 0,
  }) {
    final filtered = filterDisplayComment(raw);
    if (filtered.isEmpty) return const [];
    const proseStyle = TextStyle(
      fontSize: 14,
      height: 1.5,
      color: AppColors.pgnComment,
    );
    if (anchorPos != null && onPlayInlineLine != null) {
      return _buildProseSpans(filtered, anchorPos, anchorPly, proseStyle);
    }
    return [TextSpan(text: '$filtered ', style: proseStyle)];
  }

  /// Decide how to render a mainline-move comment: a flowing inline span list
  /// for short single-paragraph prose, or a bordered block for anything with
  /// embedded moves, Chessable markers, or multiple paragraphs. Without
  /// [bookFormatting], always plain flowing prose.
  ({Widget? block, List<InlineSpan> spans}) _renderComment(
    String raw, {
    Position? anchorPos,
    int anchorPly = 0,
  }) {
    if (!bookFormatting) {
      return (
        block: null,
        spans: _plainCommentSpans(
          raw,
          anchorPos: anchorPos,
          anchorPly: anchorPly,
        ),
      );
    }
    if (hasChessableFormatting(raw)) {
      final segments = parseRichComment(raw);
      if (segments.isNotEmpty) {
        return (
          block: _buildRichCommentBlock(
            segments,
            anchorPos: anchorPos,
            anchorPly: anchorPly,
          ),
          spans: const [],
        );
      }
    }
    final tokens = parseCommentTokens(stripEngineTokens(raw));
    if (tokens.isEmpty) return (block: null, spans: const []);

    final hasMove = tokens.any((t) => t is CommentMove);
    final paragraphs = _splitParagraphs(tokens);
    if (!hasMove && paragraphs.length <= 1) {
      return (
        block: null,
        spans: _buildCommentTokenSpans(
          tokens,
          anchorPos: anchorPos,
          anchorPly: anchorPly,
        ),
      );
    }
    return (
      block: _proseContainer(
        _buildTokenParagraphs(
          tokens,
          anchorPos: anchorPos,
          anchorPly: anchorPly,
        ),
      ),
      spans: const [],
    );
  }

  /// The bordered container used for block-style comments.
  Widget _proseContainer(Widget child) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.pgnCommentBlockBg,
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(
            color: AppColors.pgnComment.withValues(alpha: 0.55),
            width: 3,
          ),
        ),
      ),
      child: child,
    );
  }

  /// Group tokens into paragraphs. A paragraph break occurs only between two
  /// consecutive prose tokens — moves (and prose adjacent to moves) flow inline
  /// so embedded analysis lines stay on one readable line instead of one
  /// token per line.
  List<List<CommentToken>> _splitParagraphs(List<CommentToken> tokens) {
    final paragraphs = <List<CommentToken>>[];
    var current = <CommentToken>[];
    CommentToken? prev;
    for (final t in tokens) {
      if (t is CommentProse && prev is CommentProse && current.isNotEmpty) {
        paragraphs.add(current);
        current = <CommentToken>[];
      }
      current.add(t);
      prev = t;
    }
    if (current.isNotEmpty) paragraphs.add(current);
    return paragraphs;
  }

  /// Render token paragraphs as a column of flowing rich text.
  Widget _buildTokenParagraphs(
    List<CommentToken> tokens, {
    Position? anchorPos,
    int anchorPly = 0,
  }) {
    final paragraphs = _splitParagraphs(tokens);
    if (paragraphs.length == 1) {
      return Text.rich(
        TextSpan(
          children: _buildCommentTokenSpans(
            paragraphs.first,
            anchorPos: anchorPos,
            anchorPly: anchorPly,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < paragraphs.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              children: _buildCommentTokenSpans(
                paragraphs[i],
                anchorPos: anchorPos,
                anchorPly: anchorPly,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Build inline spans for a list of comment tokens: prose as flowing text,
  /// moves as clickable chips that replay their run on the board.
  List<InlineSpan> _buildCommentTokenSpans(
    List<CommentToken> tokens, {
    Position? anchorPos,
    int anchorPly = 0,
  }) {
    // Collect the moves of each run (in order) so a click can replay the line.
    final runMoves = <int, List<CommentMove>>{};
    for (final t in tokens) {
      if (t is CommentMove) (runMoves[t.runId] ??= []).add(t);
    }

    // Prose is set in the proportional default font — monospace is reserved
    // for moves (and FEN) so long English sentences read like prose, not code.
    const proseStyle = TextStyle(
      fontSize: 14,
      height: 1.5,
      color: AppColors.pgnComment,
    );

    final spans = <InlineSpan>[];
    for (final t in tokens) {
      if (t is CommentProse) {
        // When we know the board at this comment, moves written inline in the
        // prose (e.g. "…Ndf6") are detected and made clickable if legal.
        if (anchorPos != null && onPlayInlineLine != null) {
          spans.addAll(
            _buildProseSpans(t.text, anchorPos, anchorPly, proseStyle),
          );
        } else {
          spans.add(TextSpan(text: '${t.text} ', style: proseStyle));
        }
      } else if (t is CommentMove) {
        spans.add(_buildCommentMoveSpan(t, runMoves[t.runId]!));
      }
    }
    return spans;
  }

  /// Split a variation-node comment into flowing spans: prose in the
  /// proportional font, embedded moves in monospace. Unlike mainline comments
  /// these are non-interactive — we don't track a board position to anchor
  /// their moves to — so the moves are rendered as plain monospace text.
  List<InlineSpan> _variationCommentSpans(String rawComment) =>
      commentProseSpans(rawComment, bookFormatting: bookFormatting);

  /// Split a prose string into flowing text + clickable chips for any word that
  /// parses as a *legal* SAN move from [anchorPos]. The legality check filters
  /// out ordinary words that merely look move-ish.
  List<InlineSpan> _buildProseSpans(
    String text,
    Position anchorPos,
    int anchorPly,
    TextStyle proseStyle,
  ) {
    final spans = <InlineSpan>[];
    final buffer = StringBuffer();
    void flushProse() {
      if (buffer.isNotEmpty) {
        spans.add(TextSpan(text: buffer.toString(), style: proseStyle));
        buffer.clear();
      }
    }

    // Serialize the anchor position once per comment (not per word) for the
    // legality-cache key.
    final anchorFen = anchorPos.fen;
    final words = text.split(' ');
    for (int wi = 0; wi < words.length; wi++) {
      if (wi > 0) buffer.write(' ');
      final word = words[wi];
      if (word.isEmpty) continue;
      final hit = _extractLegalSanCached(word, anchorPos, anchorFen);
      if (hit == null) {
        buffer.write(word);
        continue;
      }
      buffer.write(hit.prefix);
      flushProse();
      spans.add(_buildProseMoveSpan(hit.san, anchorPly));
      buffer.write(hit.suffix);
    }
    buffer.write(' ');
    flushProse();
    return spans;
  }

  /// Memoizes [_extractLegalSan] across rebuilds. Navigating the game
  /// re-renders the whole movetext, and re-parsing every prose word's SAN from
  /// scratch each time is what made move clicks lag on heavily-annotated
  /// (book/study) PGNs. Keyed by the anchor FEN plus the word, so results are
  /// correct across positions and games; the check is a pure function of those
  /// two, so caching is always safe. Cleared wholesale past a size cap so the
  /// map can't grow without bound over a long session.
  static final Map<String, ({String prefix, String san, String suffix})?>
  _legalSanCache = {};

  ({String prefix, String san, String suffix})? _extractLegalSanCached(
    String word,
    Position pos,
    String anchorFen,
  ) {
    final key = '$anchorFen $word';
    final cached = _legalSanCache[key];
    if (cached != null || _legalSanCache.containsKey(key)) return cached;
    if (_legalSanCache.length > 50000) _legalSanCache.clear();
    final result = _extractLegalSan(word, pos);
    _legalSanCache[key] = result;
    return result;
  }

  /// Extract a legal SAN move from a single prose word, along with any leading
  /// bracket / trailing punctuation to keep rendered separately. Returns null
  /// when the word is not a legal move from [pos].
  ({String prefix, String san, String suffix})? _extractLegalSan(
    String word,
    Position pos,
  ) {
    final lead = _leadBracketRe.firstMatch(word);
    final prefix = lead?.group(0) ?? '';
    var rest = word.substring(prefix.length);
    final trail = _trailPunctRe.firstMatch(rest);
    final suffix = trail?.group(0) ?? '';
    rest = rest.substring(0, rest.length - suffix.length);
    if (rest.isEmpty) return null;
    // Strip a leading move number / ellipsis (8., 12..., …) and trailing glyphs.
    var core = rest
        .replaceFirst(_moveNumberPrefixRe, '')
        .replaceFirst(_ellipsisPrefixRe, '')
        .replaceFirst(_glyphSuffixRe, '');
    if (core.isEmpty || !_sanCoreRe.hasMatch(core)) return null;
    try {
      if (pos.parseSan(core) == null) return null;
    } catch (_) {
      return null;
    }
    return (prefix: prefix, san: core, suffix: suffix);
  }

  /// A clickable chip for a single move detected inside prose. Plays the move
  /// (a one-move inline line) from its anchor ply via [onPlayInlineLine].
  WidgetSpan _buildProseMoveSpan(String san, int anchorPly) {
    final coords = _coordsAtPly(anchorPly);
    final active = activeInlineLine;
    final isActive =
        active != null &&
        active.anchorFen == null &&
        active.cursor == 1 &&
        active.firstMoveNumber == coords.moveNumber &&
        active.firstIsWhite == coords.isWhite &&
        active.sans.length == 1 &&
        active.sans.first == san;

    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () =>
            onPlayInlineLine!(coords.moveNumber, coords.isWhite, [san], 0),
        child: Container(
          decoration: isActive
              ? BoxDecoration(
                  color: AppColors.pgnMoveCurrentBg,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: AppColors.pgnMoveCurrent, width: 1),
                )
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: Colors.transparent, width: 1),
                ),
          child: Text(
            san,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13.5,
              height: 1.5,
              color: isActive ? AppColors.pgnMoveCurrentFg : AppColors.info,
              fontWeight: FontWeight.normal,
              decoration: isActive ? null : TextDecoration.underline,
              decorationColor: AppColors.info.withValues(alpha: 0.4),
              decorationStyle: TextDecorationStyle.dotted,
            ),
          ),
        ),
      ),
    );
  }

  /// The (fullmove number, side) of a move played at [ply] half-moves in.
  ({int moveNumber, bool isWhite}) _coordsAtPly(int ply) => coordsAtPly(
    ply: ply,
    startFullmoves: startingMoveNumber,
    startWhiteToMove: startingWhiteTurn,
  );

  /// Replay the mainline into a list of positions: `[k]` is the board after
  /// `k` half-moves. Returns null when there is no start position, or when
  /// inline lines are disabled (nothing consumes the positions then).
  // Single-slot cache for the mainline replay: navigating just re-renders the
  // same game, so replaying every SAN on each rebuild is wasted work. Reused
  // while the same [moveHistory] list of the same length replays from the same
  // start position — comment/NAG edits don't change positions, and appending a
  // move (edit mode) changes the length, so both stay correct.
  static List<PgnNodeData>? _prefixCacheKeyMoves;
  static Position? _prefixCacheKeyStart;
  static int _prefixCacheKeyLength = -1;
  static List<Position>? _prefixCacheValue;

  List<Position>? _buildPrefixPositions() {
    final start = startPosition;
    if (start == null || onPlayInlineLine == null) return null;
    if (identical(_prefixCacheKeyMoves, moveHistory) &&
        identical(_prefixCacheKeyStart, start) &&
        _prefixCacheKeyLength == moveHistory.length) {
      return _prefixCacheValue;
    }
    final positions = <Position>[start];
    Position pos = start;
    for (final data in moveHistory) {
      if (data.san == '--') {
        positions.add(pos);
        continue;
      }
      final move = pos.parseSan(data.san);
      if (move == null) break;
      pos = pos.play(move);
      positions.add(pos);
    }
    _prefixCacheKeyMoves = moveHistory;
    _prefixCacheKeyStart = start;
    _prefixCacheKeyLength = moveHistory.length;
    _prefixCacheValue = positions;
    return positions;
  }

  Position? _posAt(List<Position>? prefix, int ply) =>
      (prefix != null && ply >= 0 && ply < prefix.length) ? prefix[ply] : null;

  /// A single clickable move chip inside a comment.
  WidgetSpan _buildCommentMoveSpan(CommentMove move, List<CommentMove> run) {
    final clickable = move.isClickable && onPlayInlineLine != null;
    final idxInRun = run.indexOf(move);

    // Is this the move the board is currently parked on, within the line being
    // previewed? Match the run by its first move + full SAN list, then the
    // cursor by position-in-run.
    final active = activeInlineLine;
    final isActiveMove =
        active != null &&
        active.anchorFen == run.first.anchorFen &&
        active.firstMoveNumber == run.first.moveNumber &&
        active.firstIsWhite == run.first.isWhite &&
        idxInRun == active.cursor - 1 &&
        listEquals(active.sans, run.map((m) => m.san).toList());

    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: clickable
            ? () {
                final sans = run.map((m) => m.san).toList();
                onPlayInlineLine!(
                  run.first.moveNumber,
                  run.first.isWhite,
                  sans,
                  idxInRun,
                  anchorFen: run.first.anchorFen,
                );
              }
            : null,
        child: Container(
          decoration: isActiveMove
              ? BoxDecoration(
                  color: AppColors.pgnMoveCurrentBg,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: AppColors.pgnMoveCurrent, width: 1),
                )
              // Reserve the border width so activating a move doesn't reflow.
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: Colors.transparent, width: 1),
                ),
          child: Text(
            '${move.display} ',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13.5,
              height: 1.5,
              color: isActiveMove
                  ? AppColors.pgnMoveCurrentFg
                  : (clickable ? AppColors.info : AppColors.pgnComment),
              fontWeight: FontWeight.normal,
              decoration: clickable && !isActiveMove
                  ? TextDecoration.underline
                  : null,
              decorationColor: AppColors.info.withValues(alpha: 0.4),
              decorationStyle: TextDecorationStyle.dotted,
            ),
          ),
        ),
      ),
    );
  }

  /// Build a rich comment block from Chessable-formatted content.
  Widget _buildRichCommentBlock(
    List<RichSegment> segments, {
    Position? anchorPos,
    int anchorPly = 0,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.pgnCommentBlockBg,
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(
            color: AppColors.pgnComment.withValues(alpha: 0.55),
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < segments.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            _buildRichSegmentWidget(
              segments[i],
              anchorPos: anchorPos,
              anchorPly: anchorPly,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRichSegmentWidget(
    RichSegment segment, {
    Position? anchorPos,
    int anchorPly = 0,
  }) {
    switch (segment.type) {
      case RichSegmentType.header:
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            segment.content,
            style: const TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.bold,
              height: 1.4,
              color: AppColors.pgnComment,
            ),
          ),
        );

      case RichSegmentType.blockQuote:
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.pgnComment.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(4),
            border: Border(
              left: BorderSide(
                color: AppColors.pgnComment.withValues(alpha: 0.5),
                width: 2,
              ),
            ),
          ),
          child: Text(
            segment.content,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              fontStyle: FontStyle.italic,
              color: AppColors.pgnComment.withValues(alpha: 0.85),
            ),
          ),
        );

      case RichSegmentType.bracket:
        return Text(
          '[${segment.content}]',
          style: const TextStyle(
            fontSize: 13.5,
            height: 1.4,
            fontStyle: FontStyle.italic,
            color: AppColors.pgnComment,
          ),
        );

      case RichSegmentType.fen:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.pgnComment.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: AppColors.pgnComment.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.grid_on,
                size: 14,
                color: AppColors.pgnComment.withValues(alpha: 0.75),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  segment.content,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    color: AppColors.pgnComment,
                  ),
                ),
              ),
            ],
          ),
        );

      case RichSegmentType.link:
        return Text(
          segment.content,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13.5,
            height: 1.5,
            color: AppColors.info,
            decoration: TextDecoration.underline,
            decorationColor: AppColors.info,
          ),
        );

      case RichSegmentType.text:
        return _buildTokenParagraphs(
          parseCommentTokens(segment.content),
          anchorPos: anchorPos,
          anchorPly: anchorPly,
        );
    }
  }

  /// Build variation spans for all roots at a given ply. With
  /// [ephemeralOnly], source-game variations are skipped and only the user's
  /// scratch lines render (solitaire frontier).
  List<InlineSpan> _buildVariationSpansAtPly(
    int ply, {
    bool ephemeralOnly = false,
  }) {
    var roots = variationsByPly[ply];
    if (roots == null || roots.isEmpty) return const [];
    if (ephemeralOnly) {
      roots = roots.where((r) => r.isEphemeral).toList();
      if (roots.isEmpty) return const [];
    }

    final spans = <InlineSpan>[];
    // Compute move number accounting for the starting position
    final coords = _coordsAtPly(ply);
    final moveNum = coords.moveNumber;
    final isWhiteTurn = coords.isWhite;

    for (final root in roots) {
      final bracketColor = root.isEphemeral
          ? AppColors.pgnEphemeralMove
          : AppColors.pgnVariation;

      spans.add(
        TextSpan(
          text: '( ',
          style: TextStyle(color: bracketColor, fontFamily: 'monospace'),
        ),
      );

      spans.addAll(_buildNodeSpans(root, moveNum, isWhiteTurn, true, ply));

      spans.add(
        TextSpan(
          text: ') ',
          style: TextStyle(color: bracketColor, fontFamily: 'monospace'),
        ),
      );
    }

    return spans;
  }

  /// Recursively build spans for a node and its children.
  List<InlineSpan> _buildNodeSpans(
    MoveNode node,
    int moveNumber,
    bool isWhiteTurn,
    bool isFirst,
    int branchPly,
  ) {
    final spans = <InlineSpan>[];
    final moveColor = node.isEphemeral
        ? AppColors.pgnEphemeralMove
        : AppColors.pgnVariation;
    const numColor = AppColors.pgnMoveNumber;

    // For null-move variation nodes, skip the move display entirely and just
    // show the comment inline.
    if (node.san == '--') {
      if (node.comment != null && node.comment!.isNotEmpty) {
        spans.addAll(_variationCommentSpans(node.comment!));
      }
      return spans;
    }

    if (isWhiteTurn) {
      spans.add(
        TextSpan(
          text: '$moveNumber. ',
          style: const TextStyle(color: numColor, fontFamily: 'monospace'),
        ),
      );
    } else if (isFirst) {
      spans.add(
        TextSpan(
          text: '$moveNumber... ',
          style: const TextStyle(color: numColor, fontFamily: 'monospace'),
        ),
      );
    }

    final isCurrentNode =
        analysisPath.isNotEmpty && analysisPath.last.id == node.id;

    // Variation moves show their NAG glyphs too (e.g. "Nf3!?").
    final nodeNagSuffix = (node.nags != null && node.nags!.isNotEmpty)
        ? node.nags!.where((n) => n >= 1 && n <= 6).map(nagSymbol).join()
        : '';

    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onGoToAnalysisNode(node, branchPly),
          onSecondaryTapDown: onShowVariationContextMenu != null
              ? (details) => onShowVariationContextMenu!(
                  node,
                  branchPly,
                  details.globalPosition,
                )
              : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: isCurrentNode
                ? BoxDecoration(
                    color: node.isEphemeral
                        ? AppColors.pgnEphemeralBg
                        : AppColors.pgnMoveCurrentBg,
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(
                      color: node.isEphemeral
                          ? AppColors.pgnEphemeralMove
                          : AppColors.pgnMoveCurrent,
                      width: 1,
                    ),
                  )
                // Reserve the border width so highlighting doesn't reflow.
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: Colors.transparent, width: 1),
                  ),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: node.san,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      color: isCurrentNode
                          ? AppColors.pgnMoveCurrentFg
                          : moveColor,
                      fontWeight: FontWeight.normal,
                      decoration: isCurrentNode
                          ? null
                          : TextDecoration.underline,
                      decorationColor: AppColors.onSurfaceDim.withValues(
                        alpha: 0.45,
                      ),
                      decorationStyle: TextDecorationStyle.dotted,
                    ),
                  ),
                  if (nodeNagSuffix.isNotEmpty)
                    TextSpan(
                      text: nodeNagSuffix,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isCurrentNode
                            ? AppColors.pgnMoveCurrentFg
                            : moveColor,
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

    // Show comment after the move (for non-null-move variation nodes)
    if (node.comment != null && node.comment!.isNotEmpty) {
      spans.addAll(_variationCommentSpans(node.comment!));
    }

    final nextMoveNumber = isWhiteTurn ? moveNumber : moveNumber + 1;
    final nextIsWhite = !isWhiteTurn;

    if (node.children.isNotEmpty) {
      spans.addAll(
        _buildNodeSpans(
          node.children.first,
          nextMoveNumber,
          nextIsWhite,
          false,
          branchPly,
        ),
      );

      for (int i = 1; i < node.children.length; i++) {
        final variation = node.children[i];
        final subColor = variation.isEphemeral
            ? AppColors.pgnEphemeralMove
            : AppColors.pgnVariation;

        spans.add(
          TextSpan(
            text: '( ',
            style: TextStyle(color: subColor, fontFamily: 'monospace'),
          ),
        );
        spans.addAll(
          _buildNodeSpans(
            variation,
            nextMoveNumber,
            nextIsWhite,
            true,
            branchPly,
          ),
        );
        spans.add(
          TextSpan(
            text: ') ',
            style: TextStyle(color: subColor, fontFamily: 'monospace'),
          ),
        );
      }
    }

    return spans;
  }
}
