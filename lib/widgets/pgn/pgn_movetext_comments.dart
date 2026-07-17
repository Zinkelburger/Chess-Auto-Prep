part of 'pgn_movetext_view.dart';

String _rawComment(PgnNodeData moveData) {
  if (moveData.comments == null || moveData.comments!.isEmpty) return '';
  return moveData.comments!.first;
}

/// Render a comment as plain flowing prose: engine tokens stripped, all
/// whitespace collapsed, no paragraph or block structure. Moves written in
/// the prose stay clickable when they are legal from the anchor position.
List<InlineSpan> _plainCommentSpans(
  PgnMovetextView view,
  String raw, {
  Position? anchorPos,
  int anchorPly = 0,
}) {
  final filtered = filterDisplayComment(raw);
  if (filtered.isEmpty) return const [];
  const proseStyle = PgnTextStyles.comment;
  if (anchorPos != null && view.onPlayInlineLine != null) {
    return _buildProseSpans(view, filtered, anchorPos, anchorPly, proseStyle);
  }
  return [TextSpan(text: '$filtered ', style: proseStyle)];
}

/// Decide how to render a mainline-move comment: a flowing inline span list
/// for short single-paragraph prose, or a bordered block for anything with
/// embedded moves, Chessable markers, or multiple paragraphs. Without
/// [bookFormatting], always plain flowing prose.
({Widget? block, List<InlineSpan> spans}) _renderComment(
  PgnMovetextView view,
  String raw, {
  Position? anchorPos,
  int anchorPly = 0,
}) {
  if (!view.bookFormatting) {
    return (
      block: null,
      spans: _plainCommentSpans(
        view,
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
          view,
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
        view,
        tokens,
        anchorPos: anchorPos,
        anchorPly: anchorPly,
      ),
    );
  }
  return (
    block: _proseContainer(
      _buildTokenParagraphs(
        view,
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
  PgnMovetextView view,
  List<CommentToken> tokens, {
  Position? anchorPos,
  int anchorPly = 0,
}) {
  final paragraphs = _splitParagraphs(tokens);
  if (paragraphs.length == 1) {
    return Text.rich(
      TextSpan(
        children: _buildCommentTokenSpans(
          view,
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
              view,
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
  PgnMovetextView view,
  List<CommentToken> tokens, {
  Position? anchorPos,
  int anchorPly = 0,
}) {
  // Collect the moves of each run (in order) so a click can replay the line.
  final runMoves = <int, List<CommentMove>>{};
  for (final t in tokens) {
    if (t is CommentMove) (runMoves[t.runId] ??= []).add(t);
  }

  const proseStyle = PgnTextStyles.comment;

  final spans = <InlineSpan>[];
  for (final t in tokens) {
    if (t is CommentProse) {
      // When we know the board at this comment, moves written inline in the
      // prose (e.g. "…Ndf6") are detected and made clickable if legal.
      if (anchorPos != null && view.onPlayInlineLine != null) {
        spans.addAll(
          _buildProseSpans(view, t.text, anchorPos, anchorPly, proseStyle),
        );
      } else {
        spans.add(TextSpan(text: '${t.text} ', style: proseStyle));
      }
    } else if (t is CommentMove) {
      spans.add(_buildCommentMoveSpan(view, t, runMoves[t.runId]!));
    }
  }
  return spans;
}

/// Split a variation-node comment into flowing spans: prose in the
/// proportional font, embedded moves in monospace. Unlike mainline comments
/// these are non-interactive — we don't track a board position to anchor
/// their moves to — so the moves are rendered as plain monospace text.
List<InlineSpan> _variationCommentSpans(
  PgnMovetextView view,
  String rawComment,
) => commentProseSpans(rawComment, bookFormatting: view.bookFormatting);

/// Split a prose string into flowing text + clickable chips for any word that
/// parses as a *legal* SAN move from [anchorPos]. The legality check filters
/// out ordinary words that merely look move-ish.
List<InlineSpan> _buildProseSpans(
  PgnMovetextView view,
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
    spans.add(_buildProseMoveSpan(view, hit.san, anchorPly));
    buffer.write(hit.suffix);
  }
  buffer.write(' ');
  flushProse();
  return spans;
}

/// A clickable chip for a single move detected inside prose. Plays the move
/// (a one-move inline line) from its anchor ply via [onPlayInlineLine].
WidgetSpan _buildProseMoveSpan(
  PgnMovetextView view,
  String san,
  int anchorPly,
) {
  final coords = _coordsAtPly(view, anchorPly);
  final active = view.activeInlineLine;
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
          view.onPlayInlineLine!(coords.moveNumber, coords.isWhite, [san], 0),
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
          style: (isActive ? PgnTextStyles.currentMove : PgnTextStyles.move)
              .copyWith(
                fontSize: 13.5,
                height: 1.5,
                decoration: isActive ? null : TextDecoration.underline,
                decorationColor: AppColors.onSurfaceMuted.withValues(
                  alpha: 0.5,
                ),
                decorationStyle: TextDecorationStyle.dotted,
              ),
        ),
      ),
    ),
  );
}

/// A single clickable move chip inside a comment.
WidgetSpan _buildCommentMoveSpan(
  PgnMovetextView view,
  CommentMove move,
  List<CommentMove> run,
) {
  final clickable = move.isClickable && view.onPlayInlineLine != null;
  final idxInRun = run.indexOf(move);

  // Is this the move the board is currently parked on, within the line being
  // previewed? Match the run by its first move + full SAN list, then the
  // cursor by position-in-run.
  final active = view.activeInlineLine;
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
              view.onPlayInlineLine!(
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
          style: (isActiveMove ? PgnTextStyles.currentMove : PgnTextStyles.move)
              .copyWith(
                fontSize: 13.5,
                height: 1.5,
                decoration: clickable && !isActiveMove
                    ? TextDecoration.underline
                    : null,
                decorationColor: AppColors.onSurfaceMuted.withValues(
                  alpha: 0.5,
                ),
                decorationStyle: TextDecorationStyle.dotted,
              ),
        ),
      ),
    ),
  );
}

/// Build a rich comment block from Chessable-formatted content.
Widget _buildRichCommentBlock(
  PgnMovetextView view,
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
            view,
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
  PgnMovetextView view,
  RichSegment segment, {
  Position? anchorPos,
  int anchorPly = 0,
}) {
  switch (segment.type) {
    case RichSegmentType.header:
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(segment.content, style: PgnTextStyles.commentHeader),
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
        child: Text(segment.content, style: PgnTextStyles.commentQuote),
      );

    case RichSegmentType.bracket:
      return Text('[${segment.content}]', style: PgnTextStyles.commentBracket);

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
              child: Text(segment.content, style: PgnTextStyles.commentFen),
            ),
          ],
        ),
      );

    case RichSegmentType.link:
      return Text(segment.content, style: PgnTextStyles.commentLink);

    case RichSegmentType.text:
      return _buildTokenParagraphs(
        view,
        parseCommentTokens(segment.content),
        anchorPos: anchorPos,
        anchorPly: anchorPly,
      );
  }
}
