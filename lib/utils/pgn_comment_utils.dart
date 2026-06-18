/// Shared PGN comment parsing, filtering, and movetext serialization.
///
/// Centralises helpers that were duplicated across [GameAnalysisController],
/// [PgnViewerWidget], and [InteractivePgnEditor].
library;

import 'dart:ui' show Color;

import 'package:dartchess/dartchess.dart';

// ---------------------------------------------------------------------------
// NAG (Numeric Annotation Glyph) constants and helpers
// ---------------------------------------------------------------------------

/// Standard move-quality NAG definitions following PGN spec.
/// Order: best-to-worst (toolbar display order).
class NagInfo {
  final int id;
  final String symbol;
  final String name;
  final Color color;
  const NagInfo(this.id, this.symbol, this.name, this.color);
}

/// The 6 standard move-quality NAGs with Lichess-inspired colors.
const kMoveNags = [
  NagInfo(3, '!!', 'Brilliant', Color(0xFF168226)),
  NagInfo(1, '!', 'Good move', Color(0xFF4CAF50)),
  NagInfo(5, '!?', 'Interesting', Color(0xFFEA45D8)),
  NagInfo(6, '?!', 'Dubious', Color(0xFF56B4E9)),
  NagInfo(2, '?', 'Mistake', Color(0xFFE69F00)),
  NagInfo(4, '??', 'Blunder', Color(0xFFDF5353)),
];

/// Lookup NAG info by ID. Returns null for unknown NAGs.
NagInfo? nagInfoById(int id) {
  for (final nag in kMoveNags) {
    if (nag.id == id) return nag;
  }
  return null;
}

/// Get the display symbol for a NAG ID. Returns `\$N` for unknown NAGs.
String nagSymbol(int id) => nagInfoById(id)?.symbol ?? '\$$id';

/// Get the color for a NAG ID. Returns a neutral grey for unknown NAGs.
Color nagColor(int id) => nagInfoById(id)?.color ?? const Color(0xFF9E9E9E);

// ---------------------------------------------------------------------------
// PGN comment-token regexes
// ---------------------------------------------------------------------------

/// Matches `[%eval 1.23]`, `[%eval 1.23,18]`, `[%eval #3]`, `[%eval #3,20]`.
final evalCommentRe = RegExp(r'\[%eval\s+(#?[+-]?\d+\.?\d*)(?:,(\d+))?\]');

/// Matches `[%maia 0.03]`.
final maiaCommentRe = RegExp(r'\[%maia\s+(\d+\.?\d*)\]');

/// Matches `[%maiaProbability 0.42]` — per-move Maia likelihood.
final maiaProbabilityCommentRe = RegExp(r'\[%maiaProbability\s+(\d+\.?\d*)\]');

/// Matches `[%humanFrequency 0.42]` — per-move Lichess human frequency.
final humanFrequencyCommentRe = RegExp(r'\[%humanFrequency\s+(\d+\.?\d*)\]');

/// Matches `[%cumProb 12.529%]` — cumulative line probability (percentage).
final cumProbCommentRe = RegExp(r'\[%cumProb\s+([\d.]+)%?\]');

/// Legacy `[%importance 0.85]` — cumulative line probability (0–1 fraction).
final importanceCommentRe = RegExp(r'\[%importance\s+(\d+\.?\d*)\]');

/// Matches `[%pv Nf3,Bb4,O-O,d5]`.
final pvCommentRe = RegExp(r'\[%pv\s+([^\]]+)\]');

/// Matches `[%maiatop Nf3,0.450]` — MAIA's most likely move and its prob.
final maiaTopCommentRe = RegExp(r'\[%maiatop\s+([^,\]]+),(\d+\.?\d*)\]');

// ---------------------------------------------------------------------------
// Parse helpers
// ---------------------------------------------------------------------------

/// Parse a `[%eval ...]` token into centipawns, mate-in-N, and optional depth.
({int? cp, int? mate, int? depth})? parseEvalComment(String comment) {
  final match = evalCommentRe.firstMatch(comment);
  if (match == null) return null;
  final raw = match.group(1)!;
  final depthStr = match.group(2);
  final depth = depthStr != null ? int.tryParse(depthStr) : null;
  if (raw.startsWith('#')) {
    final mate = int.tryParse(raw.substring(1));
    if (mate != null) return (cp: null, mate: mate, depth: depth);
    return null;
  }
  final cpFloat = double.tryParse(raw);
  if (cpFloat != null) {
    return (cp: (cpFloat * 100).round(), mate: null, depth: depth);
  }
  return null;
}

/// Parse a `[%maia ...]` token into a probability (0-1).
double? parseMaiaComment(String comment) {
  final match = maiaCommentRe.firstMatch(comment);
  if (match == null) return null;
  return double.tryParse(match.group(1)!);
}

/// Parse a `[%maiaProbability ...]` token into a probability (0-1).
double? parseMaiaProbabilityComment(String comment) {
  final match = maiaProbabilityCommentRe.firstMatch(comment);
  if (match == null) return null;
  return double.tryParse(match.group(1)!);
}

/// Parse a `[%humanFrequency ...]` token into a probability (0-1).
double? parseHumanFrequencyComment(String comment) {
  final match = humanFrequencyCommentRe.firstMatch(comment);
  if (match == null) return null;
  return double.tryParse(match.group(1)!);
}

/// Parse cumulative line probability from `[%cumProb ...]` (percentage) or
/// legacy `[%importance ...]` (0–1 fraction). Returns 0–1.
double? parseImportanceComment(String comment) {
  final cumMatch = cumProbCommentRe.firstMatch(comment);
  if (cumMatch != null) {
    final pct = double.tryParse(cumMatch.group(1)!);
    if (pct != null) return pct / 100.0;
  }
  final match = importanceCommentRe.firstMatch(comment);
  if (match == null) return null;
  return double.tryParse(match.group(1)!);
}

/// Parse a `[%maiatop ...]` token into the top move (SAN) and its probability.
({String move, double prob})? parseMaiaTopComment(String comment) {
  final match = maiaTopCommentRe.firstMatch(comment);
  if (match == null) return null;
  final move = match.group(1)!;
  final prob = double.tryParse(match.group(2)!);
  if (prob == null) return null;
  return (move: move, prob: prob);
}

/// Parse a `[%pv ...]` token into a SAN move list.
List<String> parsePvComment(String comment) {
  final match = pvCommentRe.firstMatch(comment);
  if (match == null) return const [];
  return match.group(1)!.split(',').where((s) => s.isNotEmpty).toList();
}

// ---------------------------------------------------------------------------
// Set / inject helpers
// ---------------------------------------------------------------------------

/// Replace or insert a `[%eval ...]` token in a comment string.
String setEvalInComment(String comment, String evalValue) {
  final token = '[%eval $evalValue]';
  if (evalCommentRe.hasMatch(comment)) {
    return comment.replaceFirst(evalCommentRe, token);
  }
  final trimmed = comment.trim();
  if (trimmed.isEmpty) return token;
  return '$token $trimmed';
}

/// Replace or append a `[%maia ...]` token in a comment string.
String setMaiaInComment(String comment, double prob) {
  final token = '[%maia ${prob.toStringAsFixed(3)}]';
  if (maiaCommentRe.hasMatch(comment)) {
    return comment.replaceFirst(maiaCommentRe, token);
  }
  final trimmed = comment.trim();
  if (trimmed.isEmpty) return token;
  return '$trimmed $token';
}

/// Replace or append a `[%maiatop ...]` token in a comment string.
String setMaiaTopInComment(String comment, String move, double prob) {
  final token = '[%maiatop $move,${prob.toStringAsFixed(3)}]';
  if (maiaTopCommentRe.hasMatch(comment)) {
    return comment.replaceFirst(maiaTopCommentRe, token);
  }
  final trimmed = comment.trim();
  if (trimmed.isEmpty) return token;
  return '$trimmed $token';
}

/// Replace or append a `[%pv ...]` token in a comment string.
String setPvInComment(String comment, List<String> pv) {
  if (pv.isEmpty) return comment;
  final token = '[%pv ${pv.join(',')}]';
  if (pvCommentRe.hasMatch(comment)) {
    return comment.replaceFirst(pvCommentRe, token);
  }
  final trimmed = comment.trim();
  if (trimmed.isEmpty) return token;
  return '$trimmed $token';
}

// ---------------------------------------------------------------------------
// Display comment filtering
// ---------------------------------------------------------------------------

final _clkRe = RegExp(r'\[%clk [^\]]+\]');
final _scoreArrowRe = RegExp(r'\([+-]?\d+\.?\d*\s*[→-]\s*[+-]?\d+\.?\d*\)');
final _classificationRe = RegExp(
    r'(Inaccuracy|Mistake|Blunder|Good move|Excellent move|Best move)\.[^.]*\.');
final _wasBestRe = RegExp(r'[A-Za-z0-9+#-]+\s+was best\.?');
final _whitespaceRe = RegExp(r'\s+');

/// Strip engine annotation tokens (`[%eval]`, `[%clk]`, `[%maia]`, `[%pv]`),
/// Lichess classification text, score arrows, and Chessable `@@...@@` wrapper
/// markers from a PGN comment, leaving only human-readable prose.
String filterDisplayComment(String comment) {
  comment = comment.replaceAll(evalCommentRe, '');
  comment = comment.replaceAll(_clkRe, '');
  comment = comment.replaceAll(maiaCommentRe, '');
  comment = comment.replaceAll(maiaProbabilityCommentRe, '');
  comment = comment.replaceAll(humanFrequencyCommentRe, '');
  comment = comment.replaceAll(cumProbCommentRe, '');
  comment = comment.replaceAll(importanceCommentRe, '');
  comment = comment.replaceAll(pvCommentRe, '');
  comment = comment.replaceAll(maiaTopCommentRe, '');
  comment = comment.replaceAll(_scoreArrowRe, '');
  comment = comment.replaceAll(_classificationRe, '');
  comment = comment.replaceAll(_wasBestRe, '');
  // Strip Chessable @@ markers but keep the content between them
  comment = comment.replaceAll(_chessableMarkerStripRe, '');
  comment = comment.replaceAll(_whitespaceRe, ' ').trim();
  if (comment.isEmpty || comment == '.,;!?') return '';
  return comment;
}

/// Matches all `@@TagName@@` markers for stripping in plain-text mode.
final _chessableMarkerStripRe = RegExp(
  r'@@(?:HeaderStart|HeaderEnd|StartBlockQuote|EndBlockQuote|'
  r'StartBracket|EndBracket|StartFEN|EndFEN|'
  r'StartSquare|EndSquare|LinkStart|LinkEnd)@@',
);

// ---------------------------------------------------------------------------
// Prose comment formatting (book-style PGNs)
// ---------------------------------------------------------------------------

/// Split `---` delimiters and collapse whitespace into readable paragraphs.
/// Returns a list of non-empty paragraph strings ready for display.
///
/// For Chessable-style double-space paragraph breaks, use [parseRichComment]
/// instead (which correctly handles `  ` as a paragraph separator in long
/// prose while avoiding false splits in short move-annotation comments).
List<String> formatProseComment(String comment) {
  final filtered = filterDisplayComment(comment);
  if (filtered.isEmpty) return const [];
  return filtered
      .split('---')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
}

// ---------------------------------------------------------------------------
// Chessable rich-comment support
// ---------------------------------------------------------------------------

/// Segment types emitted by [parseRichComment].
enum RichSegmentType {
  text,
  header,
  blockQuote,
  bracket,
  fen,
  link,
}

/// A single segment of a rich (Chessable-style) PGN comment.
class RichSegment {
  final RichSegmentType type;

  /// The textual content of the segment. For [RichSegmentType.text] this may
  /// contain paragraph breaks encoded as `\n`.
  final String content;

  const RichSegment(this.type, this.content);

  @override
  String toString() => 'RichSegment($type, "${content.length > 40 ? '${content.substring(0, 40)}...' : content}")';
}

/// Strip engine tokens but preserve Chessable `@@...@@` markers.
///
/// Crucially this preserves the double-space token structure that book-style
/// PGNs use to separate inline moves and paragraphs (unlike
/// [filterDisplayComment], which collapses all whitespace). Used by
/// [parseRichComment] and [parseCommentTokens].
String stripEngineTokens(String comment) {
  comment = comment.replaceAll(evalCommentRe, '');
  comment = comment.replaceAll(_clkRe, '');
  comment = comment.replaceAll(maiaCommentRe, '');
  comment = comment.replaceAll(maiaProbabilityCommentRe, '');
  comment = comment.replaceAll(humanFrequencyCommentRe, '');
  comment = comment.replaceAll(cumProbCommentRe, '');
  comment = comment.replaceAll(importanceCommentRe, '');
  comment = comment.replaceAll(pvCommentRe, '');
  comment = comment.replaceAll(maiaTopCommentRe, '');
  comment = comment.replaceAll(_scoreArrowRe, '');
  comment = comment.replaceAll(_classificationRe, '');
  comment = comment.replaceAll(_wasBestRe, '');
  // Collapse runs of single spaces (but preserve double-spaces for paragraph
  // detection) — replace 3+ spaces with double-space, single stays.
  comment = comment.replaceAll(RegExp(r' {3,}'), '  ');
  comment = comment.trim();
  if (comment.isEmpty || comment == '.,;!?') return '';
  return comment;
}

/// Chessable `@@...@@` marker regex. Captures tag name and inner content.
final _chessableMarkerRe = RegExp(
  r'@@(HeaderStart|HeaderEnd|StartBlockQuote|EndBlockQuote|'
  r'StartBracket|EndBracket|StartFEN|EndFEN|'
  r'StartSquare|EndSquare|LinkStart|LinkEnd)@@',
);

/// Returns true when the comment contains Chessable-style `@@...@@` markers,
/// or when it appears to use double-space paragraph breaks (long prose with
/// 2+ instances of `  ` that are not mere move-notation spacing).
bool hasChessableFormatting(String comment) {
  if (_chessableMarkerRe.hasMatch(comment)) return true;
  // Detect double-space paragraph breaks in long prose: require the comment
  // to be long enough that double-spaces are likely real paragraph separators,
  // not just spacing around move notation.
  if (comment.length > 300) {
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

    final endTag = _closingTag(tag);
    if (endTag != null) {
      // Find the matching end marker
      final endIdx = markers.indexWhere(
        (m) => m.group(1) == endTag,
        i + 1,
      );
      if (endIdx != -1) {
        final innerStart = marker.end;
        final innerEnd = markers[endIdx].start;
        final inner = stripped.substring(innerStart, innerEnd).trim();
        if (inner.isNotEmpty) {
          segments.add(RichSegment(_segmentType(tag), inner));
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
  // Split on double-space (Chessable paragraph break) and `---`
  final paragraphs = text
      .split(RegExp(r'\s{2,}|---'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();

  if (paragraphs.isEmpty) return;
  segments.add(RichSegment(RichSegmentType.text, paragraphs.join('\n')));
}

/// Map an opening tag to its expected closing tag.
String? _closingTag(String openTag) {
  switch (openTag) {
    case 'HeaderStart':
      return 'HeaderEnd';
    case 'StartBlockQuote':
      return 'EndBlockQuote';
    case 'StartBracket':
      return 'EndBracket';
    case 'StartSquare':
      return 'EndSquare';
    case 'StartFEN':
      return 'EndFEN';
    case 'LinkStart':
      return 'LinkEnd';
    default:
      return null;
  }
}

/// Map an opening tag to a [RichSegmentType].
RichSegmentType _segmentType(String openTag) {
  switch (openTag) {
    case 'HeaderStart':
      return RichSegmentType.header;
    case 'StartBlockQuote':
      return RichSegmentType.blockQuote;
    case 'StartBracket':
    case 'StartSquare':
      return RichSegmentType.bracket;
    case 'StartFEN':
      return RichSegmentType.fen;
    case 'LinkStart':
      return RichSegmentType.link;
    default:
      return RichSegmentType.text;
  }
}

// ---------------------------------------------------------------------------
// Inline-move comment tokenization (book-style PGNs)
// ---------------------------------------------------------------------------

/// A single token of a comment: either prose text or a chess move.
///
/// Book PGNs (Chessable / Forward Chess exports) embed analysis lines directly
/// in comment text, with double-spaces separating each move token (e.g.
/// `Or  40.cxb5  c4!-+  , winning the pawn ending.`). [parseCommentTokens]
/// recovers that structure so the viewer can render the moves as clickable
/// chips and flow the prose naturally instead of one-token-per-line.
sealed class CommentToken {
  const CommentToken();
}

/// A run of human-readable prose.
class CommentProse extends CommentToken {
  final String text;
  const CommentProse(this.text);

  @override
  String toString() => 'CommentProse("$text")';
}

/// A single chess move embedded in a comment.
class CommentMove extends CommentToken {
  /// The playable SAN core (e.g. `cxb5`, `Rxc4`, `O-O`), with move numbers,
  /// check/mate glyphs, annotations (`!?`) and eval symbols (`-+`) stripped.
  final String san;

  /// The original text as written, for display (e.g. `40.cxb5`, `42...Kc3?`).
  final String display;

  /// Fullmove number this move belongs to, or -1 when it could not be
  /// determined (in which case the move is shown but not clickable).
  final int moveNumber;

  /// Whether it is White's move.
  final bool isWhite;

  /// Identifier of the contiguous run of moves this belongs to. Clicking a
  /// move replays its whole run from the run's first move.
  final int runId;

  const CommentMove({
    required this.san,
    required this.display,
    required this.moveNumber,
    required this.isWhite,
    required this.runId,
  });

  bool get isClickable => moveNumber >= 0;

  @override
  String toString() => 'CommentMove($display)';
}

/// Matches one move token: optional move number + dots, SAN core, optional
/// check/mate, annotation glyphs, and eval symbols.
final _commentMoveRe = RegExp(
  r'^(?:(\d+)(\.{3}|\.))?'
  r'(O-O-O|O-O|'
  r'(?:[KQRBN][a-h1-8]?x?[a-h][1-8]|[a-h]x[a-h][1-8]|[a-h][1-8])(?:=[QRBN])?)'
  r'([+#]?)'
  r'(?:[!?]{1,2})?'
  r'(?:[-+=]{1,2}|[-+]/[-+]|±|∓|⩲|⩱)?$',
);

/// Splits a comment into tokens: double-space, newline, and `---` are all
/// token separators in the book-PGN convention.
final _commentTokenSplitRe = RegExp(r'\n|---|\s{2,}');

/// Parse engine-stripped comment text into prose / move tokens.
///
/// Pass the output of [stripEngineTokens] (which preserves the double-space
/// structure), or a [RichSegment] text body (whose `\n`s mark token breaks).
List<CommentToken> parseCommentTokens(String text) {
  final parts = text
      .split(_commentTokenSplitRe)
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty);

  final tokens = <CommentToken>[];
  var runId = 0;
  // Last move seen (regardless of interspersed prose), used both to derive
  // unnumbered moves and to decide run membership by move-number continuity.
  int? lastNumber;
  bool? lastWhite;

  for (final part in parts) {
    final m = _commentMoveRe.firstMatch(part);
    if (m == null) {
      tokens.add(CommentProse(part));
      continue;
    }

    final numStr = m.group(1);
    final dots = m.group(2);

    // Expected successor ply of the previous move.
    int? expectedNumber;
    bool? expectedWhite;
    if (lastNumber != null && lastWhite != null) {
      expectedNumber = lastWhite ? lastNumber : lastNumber + 1;
      expectedWhite = !lastWhite;
    }

    int number;
    bool white;
    if (numStr != null) {
      number = int.parse(numStr);
      white = dots != '...';
    } else if (expectedNumber != null) {
      // Unnumbered move: it is the successor of the previous move.
      number = expectedNumber;
      white = expectedWhite!;
    } else {
      number = -1;
      white = true;
    }

    // A move continues the current line when it is exactly the expected
    // successor of the previous move; otherwise it starts a new run. Lines
    // survive interspersed prose ("... is a draw: 43.Rxc4+ ...") but break
    // when the analysis jumps back to try a different move.
    final continues = number >= 0 &&
        expectedNumber != null &&
        number == expectedNumber &&
        white == expectedWhite;
    if (!continues) runId++;

    tokens.add(CommentMove(
      san: m.group(3)!,
      display: part,
      moveNumber: number,
      isWhite: white,
      runId: runId,
    ));

    if (number >= 0) {
      lastNumber = number;
      lastWhite = white;
    } else {
      lastNumber = null;
      lastWhite = null;
    }
  }

  return tokens;
}

// ---------------------------------------------------------------------------
// Movetext serialization
// ---------------------------------------------------------------------------

/// Serialize a flat list of [PgnNodeData] moves into PGN movetext with
/// move numbers, NAGs, and inline `{comment}` braces.
///
/// Appends [result] (e.g. `1-0`) unless it is null or `*`.
String buildMovetext(List<PgnNodeData> moves, {String? result}) {
  final buf = StringBuffer();
  var moveNum = 1;
  var isWhite = true;
  for (final move in moves) {
    if (isWhite) buf.write('$moveNum. ');
    buf.write('${move.san} ');
    if (move.nags != null && move.nags!.isNotEmpty) {
      for (final nag in move.nags!) {
        buf.write('\$$nag ');
      }
    }
    if (move.comments != null && move.comments!.isNotEmpty) {
      for (final c in move.comments!) {
        if (c.isNotEmpty) buf.write('{$c} ');
      }
    }
    if (!isWhite) moveNum++;
    isWhite = !isWhite;
  }
  if (result != null && result != '*') buf.write(result);
  return buf.toString().trim();
}
