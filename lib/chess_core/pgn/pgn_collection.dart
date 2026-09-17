import '../../models/pgn_game_entry.dart';
import 'pgn_text.dart' as pgn;

List<PgnGameEntry> parseMultiGamePgn(String content) {
  final entries = <PgnGameEntry>[];
  for (final chunk in pgn.splitPgnIntoGames(content)) {
    _addChunk(entries, chunk);
  }
  return entries;
}

void _addChunk(List<PgnGameEntry> entries, String chunk) {
  final trimmed = chunk.trim();
  if (trimmed.isEmpty) return;
  // A comment-only chunk (e.g. a `;`-comment banner before the first
  // `[Event` header, as in chessgames.com collection downloads) is not a
  // game; without this it would surface as a blank extra game.
  if (_isCommentOnly(trimmed)) return;
  final headers = pgn.extractHeaders(trimmed);
  final rating = int.tryParse(headers['StudyRating'] ?? '') ?? 0;
  entries.add(
    PgnGameEntry(
      headers: headers,
      pgnText: trimmed,
      studyRating: rating.clamp(0, 5),
      studySummary: headers['StudySummary'] ?? '',
    ),
  );
}

/// Leading comment/escape lines omitted by [parseMultiGamePgn]. Preserve them
/// when exporting or recovering a collection, including indented/CRLF headers
/// and headerless movetext. Stop at the first game line, never its next header.
String pgnCollectionPreamble(String content) {
  var lineStart = 0;
  while (lineStart < content.length) {
    var lineEnd = content.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = content.length;
    final line = content.substring(lineStart, lineEnd).trim();
    if (line.isNotEmpty && !pgn.isPgnCommentLine(line)) {
      return content.substring(0, lineStart).trim();
    }
    lineStart = lineEnd + 1;
  }
  return content.trim();
}

/// Whether every line of [text] is blank or a top-level comment line.  Stops
/// at the first line that is neither, so a real game is settled by its
/// first header rather than a scan of all its lines.
bool _isCommentOnly(String text) {
  var lineStart = 0;
  while (lineStart <= text.length) {
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = text.length;
    final line = text.substring(lineStart, lineEnd).trim();
    if (line.isNotEmpty && !pgn.isPgnCommentLine(line)) return false;
    lineStart = lineEnd + 1;
  }
  return true;
}
