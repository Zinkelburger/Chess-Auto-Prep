import 'package:path/path.dart' as p;

import '../chess/pgn/chapter_sections.dart' show chapterNameTag;
import '../chess/pgn/game_text.dart';
import '../chess/pgn/games_written.dart';
import '../chess/pgn/pgn_lexer.dart';
import '../chess/pgn/pgn_token.dart';
import 'edit_scope.dart';

/// Validates explicit reference intent against independently declared game
/// lineage. The ordinary edit-scope check still owns all other PGN bytes.
/// Added games have no earlier section; removed games need no surviving target.
String? sectionReferenceProblem({
  required String documentPath,
  required String before,
  required String after,
  required EditScope scope,
}) {
  final references = scope.references;
  if (references == null) return null;
  final previous = _sections(before);
  final next = _sections(after);
  final arranged = switch (scope) {
    GamesEdited(:final written) when written.appended >= 0 => GamesArranged.of(
      written,
      before: previous.length,
    ),
    GamesRearranged(:final arranged) => arranged,
    _ => null,
  };
  if (arranged == null)
    return 'Section reference changes require declared game lineage.';
  if (arranged.before != previous.length ||
      arranged.order.length != next.length) {
    return 'Section reference changes do not match the declared game counts.';
  }
  final expected = [...previous];
  final sources = <String>{};
  for (final change in references.changes) {
    if (!p.equals(documentPath, change.path))
      return 'Section references name another document.';
    if (change.to.isEmpty || change.to.trim() != change.to)
      return 'The renamed section needs a valid name.';
    if (!expected.contains(change.from))
      return 'The section to rename does not exist: ${change.from}.';
    if (change.from != change.to && expected.contains(change.to)) {
      return 'The renamed section already exists: ${change.to}.';
    }
    sources.add(change.from);
    for (var i = 0; i < expected.length; i++) {
      if (expected[i] == change.from) expected[i] = change.to;
    }
  }
  // A new game may introduce a section, but may not leave behind a name the
  // accepted rename chain eliminated. Roundtrips deliberately keep their name.
  final eliminated = sources.difference(expected.nonNulls.toSet());
  if (next.any(eliminated.contains))
    return 'The PGN still contains a section that was renamed.';
  return _retainedProblem(previous, expected, next, arranged);
}

String? _retainedProblem(
  List<String?> previous,
  List<String?> expected,
  List<String?> next,
  GamesArranged arranged,
) {
  final seen = <int>{};
  for (final (place, original) in arranged.order.indexed) {
    if (original == null) continue;
    if (original < 0 || original >= previous.length || !seen.add(original)) {
      return 'Section reference changes have invalid game lineage.';
    }
    if (next[place] != expected[original]) {
      return 'Game ${place + 1} does not carry its declared section rename.';
    }
    if (expected[original] != previous[original] &&
        !arranged.rewritten.contains(original)) {
      return 'The section rename did not declare game ${original + 1} rewritten.';
    }
  }
  return null;
}

List<String?> _sections(String text) => [
  for (final game in splitChapterText(text).games) _section(game.text),
];

/// Match the library's section semantics: first ChapterName header, trimmed;
/// neither a header-looking comment nor a later duplicate names the game.
String? _section(String text) {
  for (final token in lexHeader(text)) {
    if (token is! TagToken || token.key != chapterNameTag) continue;
    final name = token.value.trim();
    return name.isEmpty ? null : name;
  }
  return null;
}
