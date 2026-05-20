/// Shared PGN comment parsing, filtering, and movetext serialization.
///
/// Centralises helpers that were duplicated across [GameAnalysisController],
/// [PgnViewerWidget], and [InteractivePgnEditor].
library;

import 'package:dartchess/dartchess.dart';

// ---------------------------------------------------------------------------
// PGN comment-token regexes
// ---------------------------------------------------------------------------

/// Matches `[%eval 1.23]`, `[%eval 1.23,18]`, `[%eval #3]`, `[%eval #3,20]`.
final evalCommentRe =
    RegExp(r'\[%eval\s+(#?[+-]?\d+\.?\d*)(?:,(\d+))?\]');

/// Matches `[%maia 0.03]`.
final maiaCommentRe = RegExp(r'\[%maia\s+(\d+\.?\d*)\]');

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
final _scoreArrowRe =
    RegExp(r'\([+-]?\d+\.?\d*\s*[→-]\s*[+-]?\d+\.?\d*\)');
final _classificationRe = RegExp(
    r'(Inaccuracy|Mistake|Blunder|Good move|Excellent move|Best move)\.[^.]*\.');
final _wasBestRe = RegExp(r'[A-Za-z0-9+#-]+\s+was best\.?');
final _whitespaceRe = RegExp(r'\s+');

/// Strip engine annotation tokens (`[%eval]`, `[%clk]`, `[%maia]`, `[%pv]`),
/// Lichess classification text, and score arrows from a PGN comment, leaving
/// only human-readable prose.
String filterDisplayComment(String comment) {
  comment = comment.replaceAll(evalCommentRe, '');
  comment = comment.replaceAll(_clkRe, '');
  comment = comment.replaceAll(maiaCommentRe, '');
  comment = comment.replaceAll(pvCommentRe, '');
  comment = comment.replaceAll(maiaTopCommentRe, '');
  comment = comment.replaceAll(_scoreArrowRe, '');
  comment = comment.replaceAll(_classificationRe, '');
  comment = comment.replaceAll(_wasBestRe, '');
  comment = comment.replaceAll(_whitespaceRe, ' ').trim();
  if (comment.isEmpty || comment == '.,;!?') return '';
  return comment;
}

// ---------------------------------------------------------------------------
// Movetext serialization
// ---------------------------------------------------------------------------

/// Serialize a flat list of [PgnNodeData] moves into PGN movetext with
/// move numbers and inline `{comment}` braces.
///
/// Appends [result] (e.g. `1-0`) unless it is null or `*`.
String buildMovetext(List<PgnNodeData> moves, {String? result}) {
  final buf = StringBuffer();
  var moveNum = 1;
  var isWhite = true;
  for (final move in moves) {
    if (isWhite) buf.write('$moveNum. ');
    buf.write('${move.san} ');
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
