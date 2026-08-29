/// Shared PGN parsing utilities used across the repertoire builder.
///
/// Centralises helpers that were previously duplicated in
/// [RepertoireController], [OpeningTreeWidget], [RepertoireLinesBrowser],
/// and [RepertoireService].
library;

import '../models/repertoire_line.dart';
import 'movetext_builder.dart';

/// Extract the value between the first pair of double-quotes in a PGN header
/// line, e.g. `[Event "Sicilian"]` → `"Sicilian"`.
String? extractHeaderValue(String line) {
  final start = line.indexOf('"') + 1;
  final end = line.lastIndexOf('"');
  if (start > 0 && end > start) {
    return line.substring(start, end);
  }
  return null;
}

/// Escape a value for use inside a PGN header, e.g. `[Event "..."]`.
///
/// The PGN spec makes backslash the escape character inside a tag value, so
/// backslashes must be doubled *before* quotes are escaped — do it the other
/// way round and the backslash pass mangles the quote escapes it just wrote.
/// The inverse of [extractHeaderValue].
String escapeHeaderValue(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

/// Extract the display title for a PGN game string.
///
/// Prefers a `[Title ...]` header; falls back to `[Event ...]`.
///
/// Scans line by line and stops at the first non-header line after the tag
/// block: the movetext is the bulk of a game and never holds a tag pair, and
/// this runs once per row in the lines browser and outline.  Lines before
/// the first tag (a `// Color:` preamble, blank lines) are skipped, not
/// treated as the end of the block.
String extractEventTitle(String pgn) {
  String? event;
  var inTags = false;
  var start = 0;
  while (start < pgn.length) {
    var end = pgn.indexOf('\n', start);
    if (end < 0) end = pgn.length;
    final line = pgn.substring(start, end).trim();
    start = end + 1;
    if (!line.startsWith('[')) {
      if (inTags && line.isNotEmpty) break;
      continue;
    }
    inTags = true;
    if (line.startsWith('[Title ')) return extractHeaderValue(line) ?? '';
    if (event == null && line.startsWith('[Event ')) {
      event = extractHeaderValue(line) ?? '';
    }
  }
  return event ?? '';
}

/// Whether [line] starts with [currentMoves] (prefix match).
bool lineMatchesPosition(RepertoireLine line, List<String> currentMoves) {
  if (currentMoves.isEmpty) return true;
  if (currentMoves.length > line.moves.length) return false;

  for (int i = 0; i < currentMoves.length; i++) {
    if (line.moves[i] != currentMoves[i]) {
      return false;
    }
  }
  return true;
}

/// How many leading moves of [currentMoves] match [line].
int getPositionMatchDepth(RepertoireLine line, List<String> currentMoves) {
  int depth = 0;
  for (int i = 0; i < currentMoves.length && i < line.moves.length; i++) {
    if (line.moves[i] == currentMoves[i]) {
      depth++;
    } else {
      break;
    }
  }
  return depth;
}

/// Format a move list with move numbers optimised for substring search.
String formatMovesForSearch(List<String> moves) =>
    buildNumberedMovetext(moves, compact: true);
