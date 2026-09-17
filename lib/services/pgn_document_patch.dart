/// Text-level replacement of whole games inside a PGN document.
library;

import 'dart:isolate';

import '../chess_core/pgn/pgn_text.dart';

/// Run document matching and reconstruction away from the UI isolate. Call
/// inside the atomic update callback so the file lock covers the worker too.
Future<String> patchPgnDocumentAsync(
  String current,
  Map<String, String> replacements,
) => Isolate.run(() => patchPgnDocument(current, replacements));

/// Replace only games whose source text still matches the loaded revision.
/// Unrelated additions, annotations and unparsed fragments stay byte-for-byte
/// intact. Ambiguous matches are conflicts, never permission to choose a game.
///
/// [replacements] maps each game's original text to its new text. Throws a
/// [StateError] when an original is no longer present exactly once in
/// [current] — the file changed underneath the edit and nothing is written.
///
/// Scan source ranges once and assemble the output once. Re-splitting,
/// searching and copying the whole document for each game made opening-tag
/// autosaves quadratic in the size of a course.
String patchPgnDocument(String current, Map<String, String> replacements) {
  final edits = <String, String>{};
  for (final entry in replacements.entries) {
    final old = entry.key.trim();
    final updated = entry.value.trim();
    if (old == updated) continue;
    if (edits.containsKey(old) && edits[old] != updated) {
      throw StateError('Conflicting edits target the same game.');
    }
    edits[old] = updated;
  }
  if (edits.isEmpty) return current;

  final matched = <String>{};
  final result = StringBuffer();
  var copiedThrough = 0;
  for (final range in pgnGameRanges(current)) {
    final source = current.substring(range.start, range.end);
    final old = source.trim();
    // A synthetic header is not present on disk. Preserve the existing
    // conflict behavior instead of inserting it into unrelated bare text.
    if (range.prefix.isNotEmpty) continue;
    final updated = edits[old];
    if (updated == null) continue;
    if (!matched.add(old)) {
      throw StateError(
        'The game is ambiguous; its edits were not overwritten.',
      );
    }
    final start = range.start + source.length - source.trimLeft().length;
    result
      ..write(current.substring(copiedThrough, start))
      ..write(updated);
    copiedThrough = start + old.length;
  }
  if (matched.length != edits.length) {
    throw StateError(
      'The game changed on disk; its edits were not overwritten.',
    );
  }
  result.write(current.substring(copiedThrough));
  return result.toString();
}
