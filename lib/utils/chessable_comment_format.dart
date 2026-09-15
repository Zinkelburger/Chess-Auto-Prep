/// Chessable's rich-comment markup: `@@HeaderStart@@ … @@HeaderEnd@@` and its
/// siblings, plus the double-space paragraph breaks its exports use.
///
/// [parseRichComment] turns a comment into [RichSegment]s the viewer lays out
/// as headers, quotes, brackets, diagrams and links; the text between markers
/// is handed on to `parseCommentTokens` for its inline moves.
library;

import 'comment_move_tokens.dart' show hasEmbeddedFen;
import 'pgn_comment_utils.dart' show stripEngineTokens;

/// Segment types emitted by [parseRichComment].
enum RichSegmentType { text, header, blockQuote, bracket, fen, link }

/// A single segment of a rich (Chessable-style) PGN comment.
class RichSegment {
  final RichSegmentType type;

  /// The textual content of the segment. For [RichSegmentType.text] this may
  /// contain paragraph breaks encoded as `\n`.
  final String content;

  const RichSegment(this.type, this.content);

  @override
  String toString() =>
      'RichSegment($type, "${content.length > 40 ? '${content.substring(0, 40)}...' : content}")';
}

/// One `@@…@@` marker pair and the segment it wraps.
enum _ChessableMarker {
  header('HeaderStart', 'HeaderEnd', RichSegmentType.header),
  blockQuote('StartBlockQuote', 'EndBlockQuote', RichSegmentType.blockQuote),
  bracket('StartBracket', 'EndBracket', RichSegmentType.bracket),
  square('StartSquare', 'EndSquare', RichSegmentType.bracket),
  fen('StartFEN', 'EndFEN', RichSegmentType.fen),
  link('LinkStart', 'LinkEnd', RichSegmentType.link);

  const _ChessableMarker(this.openTag, this.closeTag, this.segmentType);

  final String openTag;
  final String closeTag;
  final RichSegmentType segmentType;

  /// The pair [tag] opens, or null when [tag] is a closing tag.
  static _ChessableMarker? opening(String tag) {
    for (final marker in values) {
      if (marker.openTag == tag) return marker;
    }
    return null;
  }
}

/// Chessable `@@...@@` marker regex. Captures the tag name.
final _chessableMarkerRe = RegExp(
  r'@@(HeaderStart|HeaderEnd|StartBlockQuote|EndBlockQuote|'
  r'StartBracket|EndBracket|StartFEN|EndFEN|'
  r'StartSquare|EndSquare|LinkStart|LinkEnd)@@',
);

/// Comments longer than this are assumed to use double spaces as paragraph
/// separators rather than as spacing around move notation.
const int _paragraphProseLength = 300;

/// Returns true when the comment contains Chessable-style `@@...@@` markers,
/// or when it appears to use double-space paragraph breaks (long prose with
/// 2+ instances of `  ` that are not mere move-notation spacing).
bool hasChessableFormatting(String comment) {
  if (_chessableMarkerRe.hasMatch(comment) || hasEmbeddedFen(comment)) {
    return true;
  }
  // Detect double-space paragraph breaks in long prose: require the comment
  // to be long enough that double-spaces are likely real paragraph separators,
  // not just spacing around move notation.
  if (comment.length > _paragraphProseLength) {
    final dsCount = '  '.allMatches(comment).length;
    if (dsCount >= 2) return true;
  }
  return false;
}

/// Parse a Chessable-formatted comment into a list of [RichSegment]s.
///
/// Handles:
/// - `@@HeaderStart@@...@@HeaderEnd@@` → [RichSegmentType.header]
/// - `@@StartBlockQuote@@...@@EndBlockQuote@@` → [RichSegmentType.blockQuote]
/// - `@@StartBracket@@...@@EndBracket@@` → [RichSegmentType.bracket]
/// - `@@StartSquare@@...@@EndSquare@@` → [RichSegmentType.bracket]
/// - `@@StartFEN@@...@@EndFEN@@` → [RichSegmentType.fen]
/// - `@@LinkStart@@...@@LinkEnd@@` → [RichSegmentType.link]
/// - Double-space (`  `) → paragraph break (encoded as `\n` in text segments)
///
/// Engine annotation tokens are stripped before parsing (but `@@` markers are
/// preserved for the parser to consume).
List<RichSegment> parseRichComment(String comment) {
  final stripped = stripEngineTokens(comment);
  if (stripped.isEmpty) return const [];

  final segments = <RichSegment>[];
  final markers = _chessableMarkerRe.allMatches(stripped).toList();

  if (markers.isEmpty) {
    _addTextSegments(segments, stripped);
    return segments;
  }

  var cursor = 0;
  var i = 0;

  while (i < markers.length) {
    final marker = markers[i];
    final tag = marker.group(1)!;

    // Emit any text before this marker
    if (marker.start > cursor) {
      _addTextSegments(segments, stripped.substring(cursor, marker.start));
    }

    final pair = _ChessableMarker.opening(tag);
    if (pair != null) {
      // Find the matching end marker
      final endIdx = markers.indexWhere(
        (m) => m.group(1) == pair.closeTag,
        i + 1,
      );
      if (endIdx != -1) {
        final innerStart = marker.end;
        final innerEnd = markers[endIdx].start;
        final inner = stripped.substring(innerStart, innerEnd).trim();
        if (inner.isNotEmpty) {
          segments.add(RichSegment(pair.segmentType, inner));
        }
        cursor = markers[endIdx].end;
        i = endIdx + 1;
        continue;
      }
    }

    // Unmatched/closing tag — skip it
    cursor = marker.end;
    i++;
  }

  // Remaining text after last marker
  if (cursor < stripped.length) {
    _addTextSegments(segments, stripped.substring(cursor));
  }

  return segments;
}

/// Add text segments, splitting on double-space paragraph breaks and `---`.
void _addTextSegments(List<RichSegment> segments, String text) {
  final paragraphs = text
      .split(RegExp(r'\s{2,}|---'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();

  if (paragraphs.isEmpty) return;
  segments.add(RichSegment(RichSegmentType.text, paragraphs.join('\n')));
}
