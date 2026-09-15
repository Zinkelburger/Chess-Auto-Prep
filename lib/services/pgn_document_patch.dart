/// Text-level replacement of whole games inside a PGN document.
library;

import 'pgn_parsing_service.dart';

/// Replace only games whose source text still matches the loaded revision.
/// Unrelated additions, annotations and unparsed fragments stay byte-for-byte
/// intact. Ambiguous matches are conflicts, never permission to choose a game.
///
/// [replacements] maps each game's original text to its new text. Throws a
/// [StateError] when an original is no longer present exactly once in
/// [current] — the file changed underneath the edit and nothing is written.
String patchPgnDocument(String current, Map<String, String> replacements) {
  var result = current;
  for (final entry in replacements.entries) {
    final old = entry.key.trim();
    final updated = entry.value.trim();
    if (old == updated) continue;
    final chunks = splitPgnIntoGames(result);
    if (chunks.where((chunk) => chunk.trim() == old).length != 1) {
      throw StateError(
        'The game changed on disk; its edits were not overwritten.',
      );
    }
    final start = result.indexOf(old);
    if (start < 0 || result.indexOf(old, start + old.length) >= 0) {
      throw StateError(
        'The game is ambiguous; its edits were not overwritten.',
      );
    }
    result = result.replaceRange(start, start + old.length, updated);
  }
  return result;
}
