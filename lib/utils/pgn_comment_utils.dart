/// The machine side of a PGN comment: the `[%tag …]` tokens the app writes
/// and reads back, how to strip them for display, and how to serialize a
/// parsed game.
///
/// Book-style comment *structure* lives next door: `move_metrics.dart` reads
/// a generated repertoire's per-move facts, `chessable_comment_format.dart`
/// parses Chessable's `@@…@@` markers and `comment_move_tokens.dart` recovers
/// the inline analysis lines book PGNs embed in prose.
library;

import 'package:dartchess/dartchess.dart';

// ---------------------------------------------------------------------------
// Multi-block comments
// ---------------------------------------------------------------------------

/// Every `{}` block a PGN attached to one move, as one string.
///
/// dartchess keeps them as a list, but the app's own model ([MoveNode]) and
/// every editing surface treat a move as having one comment. Joining is the
/// only lossless way to bridge that: reading `comments.first` silently dropped
/// whichever block came second, which is how Lichess study exports (prose in
/// one block, `[%cal]` shapes in another) and book PGNs lost half their notes.
String joinComments(List<String>? comments) {
  if (comments == null || comments.isEmpty) return '';
  return comments.where((c) => c.trim().isNotEmpty).join(' ');
}

// ---------------------------------------------------------------------------
// PGN comment-token regexes
// ---------------------------------------------------------------------------

/// Matches `[%eval 1.23]`, `[%eval 1.23,18]`, `[%eval #3]`, `[%eval #3,20]`.
final _evalCommentRe = RegExp(r'\[%eval\s+(#?[+-]?\d+\.?\d*)(?:,(\d+))?\]');

/// Matches `[%maia 0.03]`.
final _maiaCommentRe = RegExp(r'\[%maia\s+(\d+\.?\d*)\]');

/// Matches `[%cumProb 12.529%]` — cumulative line probability (percentage).
final _cumProbCommentRe = RegExp(r'\[%cumProb\s+([\d.]+)%?\]');

/// Legacy `[%importance 0.85]` — cumulative line probability (0–1 fraction).
final _importanceCommentRe = RegExp(r'\[%importance\s+(\d+\.?\d*)\]');

/// Matches `[%transposes Nf3 d5 d4 Nf6]` — the move order a line cut at a
/// transposition continues in.  Space-separated SAN from the game's start.
final _transposesCommentRe = RegExp(r'\[%transposes\s+([^\]]+)\]');

/// Legacy PV payloads and references to an engine line stored as a real RAV.
final pvCommentRe = RegExp(r'\[%(?:pv|bestline)\s+([^\]]+)\]');
final legacyPvCommentRe = RegExp(r'\[%pv\s+([^\]]+)\]');
final bestLineCommentRe = RegExp(r'\[%bestline\s+([^\]]+)\]');

/// Matches `[%maiatop Nf3,0.450]` — MAIA's most likely move and its prob.
final _maiaTopCommentRe = RegExp(r'\[%maiatop\s+([^,\]]+),(\d+\.?\d*)\]');

/// Catch-all for any `[%tag ...]` annotation token — the app's own metrics,
/// Lichess `[%cal]` arrows / `[%csl]` circles, `[%clk]` clocks — so scraped
/// PGNs never leak raw tokens into displayed prose.
final _anyPgnTokenRe = RegExp(r'\[%[a-zA-Z]+[^\]]*\]');

// ---------------------------------------------------------------------------
// Parse helpers
// ---------------------------------------------------------------------------

/// The moves a `[%transposes …]` token names, or null when absent.
List<String>? parseTransposesToken(String? comment) {
  if (comment == null) return null;
  final m = _transposesCommentRe.firstMatch(comment);
  if (m == null) return null;
  final moves = m.group(1)!.trim().split(RegExp(r'\s+'));
  return moves.where((s) => s.isNotEmpty).toList();
}

/// Parse a `[%eval ...]` token into centipawns, mate-in-N, and optional depth.
({int? cp, int? mate, int? depth})? parseEvalComment(String comment) {
  final match = _evalCommentRe.firstMatch(comment);
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
  final match = _maiaCommentRe.firstMatch(comment);
  if (match == null) return null;
  return double.tryParse(match.group(1)!);
}

/// Parse cumulative line probability from `[%cumProb ...]` (percentage) or
/// legacy `[%importance ...]` (0–1 fraction). Returns 0–1.
double? parseImportanceComment(String comment) {
  final cumMatch = _cumProbCommentRe.firstMatch(comment);
  if (cumMatch != null) {
    final pct = double.tryParse(cumMatch.group(1)!);
    if (pct != null) return pct / 100.0;
  }
  final match = _importanceCommentRe.firstMatch(comment);
  if (match == null) return null;
  return double.tryParse(match.group(1)!);
}

/// Parse a `[%maiatop ...]` token into the top move (SAN) and its probability.
({String move, double prob})? parseMaiaTopComment(String comment) {
  final match = _maiaTopCommentRe.firstMatch(comment);
  if (match == null) return null;
  final move = match.group(1)!;
  final prob = double.tryParse(match.group(2)!);
  if (prob == null) return null;
  return (move: move, prob: prob);
}

/// Parse a legacy `[%pv ...]` or stored `[%bestline ...]` path into SANs.
List<String> parsePvComment(String comment) {
  final match = pvCommentRe.firstMatch(comment);
  if (match == null) return const [];
  return match.group(1)!.split(',').where((s) => s.isNotEmpty).toList();
}

// ---------------------------------------------------------------------------
// Set / inject helpers
// ---------------------------------------------------------------------------

/// How many plies of a game may lack an `[%eval]` and still leave the game
/// counting as analyzed.
///
/// Two, because a full pass legitimately leaves that many behind: the mating
/// move carries no score (mate-0 has no sign — the reader derives the result
/// from the board), and a pass that scores positions *between* moves has
/// nothing to say about the very last one. Readers of stored evals and writers
/// of them must agree on this number or a game one side wrote is a game the
/// other side rejects — see `parseCachedEvals`.
const int kMaxUnevaluatedPlies = 2;

/// Format a White-normalized score as a Lichess-compatible `[%eval]` comment
/// value, with optional depth suffix (e.g. `1.23,18` or `#3,20`).
String formatEvalCommentValue({int? scoreCp, int? scoreMate, int? depth}) {
  final String base;
  if (scoreMate != null) {
    base = '#$scoreMate';
  } else if (scoreCp != null) {
    base = (scoreCp / 100.0).toStringAsFixed(2);
  } else {
    base = '0.00';
  }
  return depth != null ? '$base,$depth' : base;
}

/// Replace the token [existing] matches in [comment] with [token], or add
/// [token] when there is none — in front of the prose when [prepend], after
/// it otherwise.
String _upsertToken(
  String comment,
  RegExp existing,
  String token, {
  bool prepend = false,
}) {
  if (existing.hasMatch(comment)) {
    return comment.replaceFirst(existing, token);
  }
  final trimmed = comment.trim();
  if (trimmed.isEmpty) return token;
  return prepend ? '$token $trimmed' : '$trimmed $token';
}

/// Replace or insert a `[%eval ...]` token in a comment string.
String setEvalInComment(String comment, String evalValue) =>
    _upsertToken(comment, _evalCommentRe, '[%eval $evalValue]', prepend: true);

/// Replace or append a `[%maia ...]` token in a comment string.
String setMaiaInComment(String comment, double prob) =>
    _upsertToken(comment, _maiaCommentRe, '[%maia ${prob.toStringAsFixed(3)}]');

/// Replace or append a `[%maiatop ...]` token in a comment string.
String setMaiaTopInComment(String comment, String move, double prob) =>
    _upsertToken(
      comment,
      _maiaTopCommentRe,
      '[%maiatop $move,${prob.toStringAsFixed(3)}]',
    );

/// Replace or append a `[%pv ...]` token in a comment string.
String setPvInComment(String comment, List<String> pv) {
  if (pv.isEmpty) return comment;
  return _upsertToken(comment, pvCommentRe, '[%pv ${pv.join(',')}]');
}

// ---------------------------------------------------------------------------
// Display comment filtering
// ---------------------------------------------------------------------------

/// cutechess's per-move engine comment — `+0.31/24 2.001s`, `-M3/18 0.500s`,
/// `book 0.010s` — which engine-vs-engine PGNs (this app's own tournaments,
/// cutechess-cli, Arena) attach to *every* move. It is measurement, not prose,
/// and a comment on every ply puts every move on its own row in the viewer.
final _engineMoveCommentRe = RegExp(
  r'(?:^|\s)(?:[+-]M?\d+(?:\.\d+)?|book)(?:/\d+)?\s+\d+(?:\.\d+)?s(?=$|[\s,])',
);
final _scoreArrowRe = RegExp(r'\([+-]?\d+\.?\d*\s*[→-]\s*[+-]?\d+\.?\d*\)');
final _classificationRe = RegExp(
  r'(Inaccuracy|Mistake|Blunder|Good move|Excellent move|Best move)\.[^.]*\.',
);
final _wasBestRe = RegExp(r'[A-Za-z0-9+#-]+\s+was best\.?');
final _whitespaceRe = RegExp(r'\s+');

/// Matches all `@@TagName@@` markers for stripping in plain-text mode.
final _chessableMarkerStripRe = RegExp(
  r'@@(?:HeaderStart|HeaderEnd|StartBlockQuote|EndBlockQuote|'
  r'StartBracket|EndBracket|StartFEN|EndFEN|'
  r'StartSquare|EndSquare|LinkStart|LinkEnd)@@',
);

/// The `[%tag …]` tokens in [comment], in the order they appear.
///
/// These are machine annotations the app writes and reads back: `[%eval]` and
/// `[%pv]` are what the analysis viewer draws, `[%clk]` is the clock a
/// downloaded game came with. A comment editor must not make the user
/// responsible for keeping them alive — it shows [commentProse] and hands the
/// edit to [mergeCommentProse], which puts them back.
List<String> pgnAnnotationTokens(String comment) =>
    _anyPgnTokenRe.allMatches(comment).map((m) => m[0]!).toList();

/// [comment] with its `[%tag …]` tokens removed: what a person actually
/// typed. Internal spacing is left alone, because book PGNs carry structure
/// in their double spaces.
String commentProse(String comment) =>
    comment.replaceAll(_anyPgnTokenRe, '').trim();

/// Edited [prose] with [original]'s `[%tag …]` tokens put back in front.
String mergeCommentProse(String original, String prose) {
  final tokens = pgnAnnotationTokens(original);
  final text = prose.trim();
  if (tokens.isEmpty) return text;
  final joined = tokens.join(' ');
  return text.isEmpty ? joined : '$joined $text';
}

/// [comment] with every `[%tag …]` token removed and nothing else touched.
///
/// The cheap half of [filterDisplayComment], for callers that only need to
/// know whether a comment is *all* tokens — a test that runs over every ply of
/// a game on every movetext rebuild, where the full filter's passes would be
/// felt.
String stripPgnTokens(String comment) => comment.replaceAll(_anyPgnTokenRe, '');

/// Everything in [comment] a machine wrote and a reader should not see:
/// `[%tag …]` tokens, cutechess per-move readouts, Lichess classification
/// sentences and score arrows. Whitespace is left for the caller to settle.
String _stripMachineAnnotations(String comment) => comment
    .replaceAll(_anyPgnTokenRe, '')
    .replaceAll(_engineMoveCommentRe, ' ')
    .replaceAll(_scoreArrowRe, '')
    .replaceAll(_classificationRe, '');

/// A stripped comment that held nothing but annotations reads as empty.
String _emptyIfOnlyPunctuation(String comment) =>
    comment.isEmpty || comment == '.,;!?' ? '' : comment;

/// Strip engine annotation tokens (`[%eval]`, `[%clk]`, `[%maia]`, `[%pv]`),
/// cutechess-style per-move engine readouts, Lichess classification text,
/// score arrows, and Chessable `@@...@@` wrapper markers from a PGN comment,
/// leaving only human-readable prose.
String filterDisplayComment(String comment) {
  final stripped = _stripMachineAnnotations(comment)
      .replaceAll(_wasBestRe, '')
      // Strip Chessable @@ markers but keep the content between them.
      .replaceAll(_chessableMarkerStripRe, '')
      .replaceAll(_whitespaceRe, ' ')
      .trim();
  return _emptyIfOnlyPunctuation(stripped);
}

/// Strip engine tokens but preserve Chessable `@@...@@` markers.
///
/// Crucially this preserves the double-space token structure that book-style
/// PGNs use to separate inline moves and paragraphs (unlike
/// [filterDisplayComment], which collapses all whitespace). Used by
/// `parseRichComment` and `parseCommentTokens`.
String stripEngineTokens(String comment) {
  final stripped = _stripMachineAnnotations(comment)
      .replaceAll(_wasBestRe, '')
      // Collapse runs of single spaces (but preserve double-spaces for
      // paragraph detection) — replace 3+ spaces with double-space.
      .replaceAll(RegExp(r' {3,}'), '  ')
      .trim();
  return _emptyIfOnlyPunctuation(stripped);
}

// ---------------------------------------------------------------------------
// Movetext serialization
// ---------------------------------------------------------------------------

/// A whole parsed game as PGN movetext: the mainline **and** every variation,
/// with NAGs, comments, and the game's own opening comment, headers stripped
/// so the caller can splice it back under the game's existing header block.
///
/// This is the **only** serializer for a game that was parsed from text, and
/// the one anything that rewrites a game the reader owns must use. There used
/// to be a second one that took a flat `List<PgnNodeData>` — which cannot
/// carry a variation, a game comment or a `[FEN]` start — and storing its
/// output deleted every sideline and the game's opening comment, machine
/// tokens included, from the reader's own file. It is gone rather than
/// documented: a lossy writer beside a lossless one, both feeding the same
/// sink, is the shape of that bug. A caller that genuinely holds only a flat
/// move list it built itself (a puzzle solution, a downloaded game's plies)
/// wants `buildNumberedMovetext`.
///
/// Serialization is dartchess's own `makePgn`, which is why this takes the
/// tree rather than a list: variations, `{}` escaping and the numbering that
/// [fen] implies all come from there rather than from a second writer here.
/// [result] is written as the game terminator (`*` when absent).
String buildGameMovetext({
  required PgnNode<PgnNodeData> moves,
  List<String> comments = const [],
  String? fen,
  String? result,
}) {
  final game = PgnGame<PgnNodeData>(
    headers: {
      if (fen != null && fen.isNotEmpty) 'FEN': fen,
      // Never empty, so `makePgn` always writes a header block and the
      // blank line below is always the movetext boundary.
      'Result': (result == null || result.isEmpty) ? '*' : result,
    },
    moves: moves,
    comments: comments,
  );
  final text = game.makePgn();
  final blankLine = text.indexOf('\n\n');
  return (blankLine < 0 ? text : text.substring(blankLine + 2)).trim();
}
