/// Shared prose rendering for PGN comments.
///
/// Both the PGN viewer's movetext and the repertoire builder's interactive
/// editor render move comments through [commentProseSpans], so a comment
/// reads identically in both surfaces: proportional prose (not code), engine
/// tokens stripped, and — with [bookFormatting] — embedded moves set in
/// monospace.
library;

import 'package:flutter/material.dart';

import '../../theme/pgn_text_styles.dart';
import '../../utils/pgn_comment_utils.dart'
    show
        filterDisplayComment,
        parseCommentTokens,
        stripEngineTokens,
        CommentMove,
        CommentProse;

/// Build flowing spans for a raw PGN comment.
///
/// Without [bookFormatting] the whole comment is one prose run (scraped PGNs
/// are messy, so no structure is inferred). With it, embedded moves render in
/// monospace while surrounding prose stays proportional. Returns an empty
/// list when nothing displayable remains after filtering.
/// [style] overrides the resolved prose style wholesale — the movetext view
/// passes the depth-scaled comment style so a sideline's annotation carries the
/// same ink and size as the sideline itself.
List<InlineSpan> commentProseSpans(
  String rawComment, {
  double fontSize = 13.5,
  double height = 1.4,
  bool bookFormatting = false,
  TextStyle? style,
}) {
  final filtered = filterDisplayComment(
    rawComment.replaceAll('{', '').replaceAll('}', ''),
  );
  if (filtered.isEmpty) return const [];

  final proseStyle =
      style ??
      PgnTextStyles.comment.copyWith(fontSize: fontSize, height: height);
  if (!bookFormatting) {
    return [TextSpan(text: '$filtered ', style: proseStyle)];
  }

  final moveStyle = PgnTextStyles.move.copyWith(
    fontSize: proseStyle.fontSize,
    height: proseStyle.height,
    color: proseStyle.color,
    fontStyle: FontStyle.normal,
  );
  final spans = <InlineSpan>[];
  for (final t in parseCommentTokens(stripEngineTokens(filtered))) {
    if (t is CommentMove) {
      spans.add(TextSpan(text: '${t.display} ', style: moveStyle));
    } else if (t is CommentProse) {
      spans.add(TextSpan(text: '${t.text} ', style: proseStyle));
    }
  }
  return spans;
}
