/// Shared PGN parsing utilities used across the repertoire builder.
///
/// Centralises helpers that were previously duplicated in
/// [RepertoireController], [OpeningTreeWidget], [RepertoireLinesBrowser],
/// and [RepertoireService].
library;

import '../models/repertoire_line.dart';

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

/// Extract the display title for a PGN game string.
///
/// Prefers a `[Title ...]` header; falls back to `[Event ...]`.
String extractEventTitle(String pgn) {
  final lines = pgn.split('\n');

  for (final line in lines) {
    if (line.trim().startsWith('[Title ')) {
      return extractHeaderValue(line) ?? '';
    }
  }
  for (final line in lines) {
    if (line.trim().startsWith('[Event ')) {
      return extractHeaderValue(line) ?? '';
    }
  }
  return '';
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

/// Format a move list with move numbers, e.g. `1.e4 e5 2.Nf3`.
String formatMoves(List<String> moves) {
  final buffer = StringBuffer();
  for (int i = 0; i < moves.length; i++) {
    if (i % 2 == 0) {
      if (i > 0) buffer.write(' ');
      buffer.write('${(i ~/ 2) + 1}.');
    }
    buffer.write(moves[i]);
    if (i < moves.length - 1 && i % 2 == 1) buffer.write(' ');
  }
  return buffer.toString();
}

/// Like [formatMoves] but optimised for substring search (no trailing trim).
String formatMovesForSearch(List<String> moves) {
  final buffer = StringBuffer();
  for (int i = 0; i < moves.length; i++) {
    if (i % 2 == 0) {
      buffer.write('${(i ~/ 2) + 1}.');
    }
    buffer.write(moves[i]);
    buffer.write(' ');
  }
  return buffer.toString().trim();
}
