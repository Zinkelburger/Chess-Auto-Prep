part of 'pgn_movetext_view.dart';

/// The move's comment as the inline editor should show it: every block joined,
/// so editing it edits all of it (see `_writeWholeComment`).
String _rawComment(PgnNodeData moveData) => joinComments(moveData.comments);

/// The generated `[%...]` metrics of a move as one quiet run — "eval +0.31 ·
/// only move · 42% likely".
///
/// Empty for every comment a human wrote, which is what makes this safe to
/// call on all of them: the tokens only exist in generated repertoires, and
/// [filterDisplayComment] strips them out of the prose beside it, so the two
/// renderers never show the same thing twice.
List<InlineSpan> _metricsSpans(String raw, {int depth = 0}) {
  final summary = MoveMetrics.parse(raw).summary;
  if (summary.isEmpty) return const [];
  return [TextSpan(text: '$summary ', style: PgnTextStyles.metricsAt(depth))];
}

/// Ordinary prose, including course exports without double-space markup.
({Widget? block, List<InlineSpan> spans}) _renderProseComment(
  PgnMovetextView view,
  String raw, {
  Position? anchorPos,
  bool interactive = true,
}) {
  final anchor = anchorPos ?? view.startPosition;
  if (anchor == null) {
    return (block: null, spans: _emphasisSpans(filterDisplayComment(raw)));
  }
  final paragraphs = parseProseComment(
    stripEngineTokens(raw).replaceAll(RegExp(r'[ \t]+'), ' '),
    anchor: anchor,
    positions: _buildPrefixPositions(view) ?? const [],
  );
  final runs = <int, List<CommentMove>>{};
  for (final move in paragraphs.expand((p) => p).whereType<CommentMove>()) {
    (runs[move.runId] ??= []).add(move);
  }
  List<InlineSpan> spansFor(List<CommentToken> paragraph) => [
    for (final token in paragraph)
      if (token is CommentProse)
        ..._emphasisSpans(token.text)
      else if (token is CommentMove)
        _buildCommentMoveSpan(
          view,
          token,
          runs[token.runId]!,
          interactive: interactive,
          trailingSpace: false,
        ),
  ];
  if (paragraphs.length <= 1) {
    return (
      block: null,
      spans: paragraphs.isEmpty ? [] : spansFor(paragraphs.single),
    );
  }
  return (
    block: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < paragraphs.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          Text.rich(TextSpan(children: spansFor(paragraphs[i]))),
        ],
      ],
    ),
    spans: const [],
  );
}

List<InlineSpan> _emphasisSpans(String text) {
  final style = PgnTextStyles.commentAt(0);
  final spans = <InlineSpan>[];
  var offset = 0;
  for (final match in RegExp(r'\*\*([^*]+)\*\*').allMatches(text)) {
    if (match.start > offset) {
      spans.add(
        TextSpan(text: text.substring(offset, match.start), style: style),
      );
    }
    spans.add(
      TextSpan(
        text: match[1],
        style: style.copyWith(fontWeight: FontWeight.w600),
      ),
    );
    offset = match.end;
  }
  if (offset < text.length) {
    spans.add(TextSpan(text: text.substring(offset), style: style));
  }
  return spans;
}

/// Decide how to render a mainline-move comment: a flowing inline span list
/// for short single-paragraph prose, or a paragraph column for anything with
/// embedded moves, Chessable markers, or multiple paragraphs. Recognizable
/// book formatting is automatic; short ordinary comments stay plain prose.
({Widget? block, List<InlineSpan> spans}) _renderComment(
  PgnMovetextView view,
  String raw, {
  Position? anchorPos,
  int anchorPly = 0,
  bool interactive = true,
}) {
  // Explicit Chessable / Forward Chess markup is safe to recognize
  // automatically. The opt-in remains relevant for ambiguous double spaces
  // in ordinary PGNs, but a real header/quote/FEN marker should never be shown
  // as a raw wall of punctuation.
  raw = normalizeCourseCommentSpacing(raw);
  final richFormatting = hasChessableFormatting(raw);
  if (!view.bookFormatting && !richFormatting) {
    return _renderProseComment(
      view,
      raw,
      anchorPos: anchorPos,
      interactive: interactive,
    );
  }
  if (richFormatting) {
    // Editorial parentheses belong inside the sentence. Flatten only these
    // delimiters before segmenting so nested diagrams remain visible and a
    // move sequence continues through an intervening aside.
    final segments = parseRichComment(
      raw
          .replaceAll(RegExp(r'@@Start(?:Bracket|Square)@@'), '(')
          .replaceAll(RegExp(r'@@End(?:Bracket|Square)@@'), ')'),
    );
    if (segments.isNotEmpty) {
      return (
        block: _buildRichCommentBlock(
          view,
          segments,
          anchorPos: anchorPos,
          anchorPly: anchorPly,
          interactive: interactive,
        ),
        spans: const [],
      );
    }
  }
  final tokens = parseCommentTokens(stripEngineTokens(raw));
  if (tokens.isEmpty) return (block: null, spans: const []);

  final hasMove = tokens.any((t) => t is CommentMove || t is CommentDiagram);
  final paragraphs = _splitParagraphs(tokens);
  if (!hasMove && paragraphs.length <= 1) {
    return (
      block: null,
      spans: _buildCommentTokenSpans(
        view,
        tokens,
        anchorPos: anchorPos,
        anchorPly: anchorPly,
        interactive: interactive,
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
        interactive: interactive,
      ),
    ),
    spans: const [],
  );
}

/// Prose shares the document background at every length and nesting depth.
Widget _proseContainer(Widget child) =>
    SizedBox(width: double.infinity, child: child);

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
  bool interactive = true,
}) {
  final paragraphs = _splitParagraphs(tokens);
  final runMoves = <int, List<CommentMove>>{};
  for (final token in tokens.whereType<CommentMove>()) {
    (runMoves[token.runId] ??= []).add(token);
  }
  final children = <Widget>[];
  for (final paragraph in paragraphs) {
    final pending = <CommentToken>[];
    void flush() {
      if (pending.isEmpty) return;
      children.add(
        Text.rich(
          TextSpan(
            children: _buildCommentTokenSpans(
              view,
              List.of(pending),
              anchorPos: anchorPos,
              anchorPly: anchorPly,
              interactive: interactive,
              allRunMoves: runMoves,
            ),
          ),
        ),
      );
      pending.clear();
    }

    for (final token in paragraph) {
      if (token is CommentDiagram) {
        flush();
        children.add(CommentDiagramBoard(fen: token.fen));
      } else {
        pending.add(token);
      }
    }
    flush();
  }
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(height: 12),
        children[i],
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
  bool interactive = true,
  Map<int, List<CommentMove>>? allRunMoves,
}) {
  // Collect the moves of each run (in order) so a click can replay the line.
  final runMoves = allRunMoves ?? <int, List<CommentMove>>{};
  if (allRunMoves == null) {
    for (final t in tokens.whereType<CommentMove>()) {
      (runMoves[t.runId] ??= []).add(t);
    }
  }

  final proseStyle = PgnTextStyles.commentAt(0);

  final spans = <InlineSpan>[];
  for (final t in tokens) {
    if (t is CommentProse) {
      // When we know the board at this comment, moves written inline in the
      // prose (e.g. "…Ndf6") are detected and made clickable if legal.
      if (interactive && anchorPos != null && view.onPlayInlineLine != null) {
        spans.addAll(
          _buildProseSpans(view, t.text, anchorPos, anchorPly, proseStyle),
        );
      } else {
        spans.add(TextSpan(text: '${t.text} ', style: proseStyle));
      }
    } else if (t is CommentMove) {
      spans.add(
        _buildCommentMoveSpan(
          view,
          t,
          runMoves[t.runId]!,
          interactive: interactive,
        ),
      );
    }
  }
  return spans;
}

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
    child: Tooltip(
      message: 'Preview comment move',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => view.onPlayInlineLine!(
            coords.moveNumber,
            coords.isWhite,
            [san],
            0,
          ),
          child: Container(
            decoration: isActive
                ? BoxDecoration(
                    color: AppColors.pgnMoveCurrentBg,
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(
                      color: AppColors.pgnMoveCurrent,
                      width: 1,
                    ),
                  )
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: Colors.transparent, width: 1),
                  ),
            child: Text(
              san,
              style: (isActive ? PgnTextStyles.currentMove : PgnTextStyles.move)
                  .copyWith(
                    fontSize: 16,
                    height: 1.72,
                    decoration: isActive ? null : TextDecoration.underline,
                    decorationColor: AppColors.onSurfaceMuted.withValues(
                      alpha: 0.5,
                    ),
                    decorationStyle: TextDecorationStyle.dotted,
                  ),
            ),
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
  List<CommentMove> run, {
  TextStyle? moveStyle,
  bool interactive = true,
  bool trailingSpace = true,
}) {
  final clickable =
      interactive && move.isClickable && view.onPlayInlineLine != null;
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

  final baseMoveStyle = moveStyle ?? PgnTextStyles.move;
  return WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: Tooltip(
      message: clickable ? 'Preview comment move' : 'Move in comment',
      child: MouseRegion(
        cursor: clickable ? SystemMouseCursors.click : MouseCursor.defer,
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
                    border: Border.all(
                      color: AppColors.pgnMoveCurrent,
                      width: 1,
                    ),
                  )
                // Reserve the border width so activating a move doesn't reflow.
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: Colors.transparent, width: 1),
                  ),
            child: Text(
              '${move.display}${trailingSpace ? ' ' : ''}',
              style:
                  (isActiveMove
                          ? baseMoveStyle.copyWith(
                              color: AppColors.pgnMoveCurrentFg,
                              fontWeight: FontWeight.w600,
                            )
                          : baseMoveStyle)
                      .copyWith(
                        fontSize: 16,
                        height: 1.72,
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
  bool interactive = true,
}) {
  final children = <Widget>[];
  final text = StringBuffer();
  void flush() {
    if (text.isEmpty) return;
    children.add(
      _buildTokenParagraphs(
        view,
        parseCommentTokens(text.toString()),
        anchorPos: anchorPos,
        anchorPly: anchorPly,
        interactive: interactive,
      ),
    );
    text.clear();
  }

  for (final segment in segments) {
    if (segment.type == RichSegmentType.text ||
        segment.type == RichSegmentType.fen) {
      // Tokenize the complete passage together: a diagram anchors all moves
      // of the following run, even across paragraphs and editorial asides.
      text.writeln(segment.content);
    } else {
      flush();
      children.add(
        _buildRichSegmentWidget(
          view,
          segment,
          anchorPos: anchorPos,
          anchorPly: anchorPly,
          interactive: interactive,
        ),
      );
    }
  }
  flush();
  return _proseContainer(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 15),
          children[i],
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
  bool interactive = true,
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
      return CommentDiagramBoard(fen: segment.content);

    case RichSegmentType.link:
      return Text(segment.content, style: PgnTextStyles.commentLink);

    case RichSegmentType.text:
      return _buildTokenParagraphs(
        view,
        parseCommentTokens(segment.content),
        anchorPos: anchorPos,
        anchorPly: anchorPly,
        interactive: interactive,
      );
  }
}
