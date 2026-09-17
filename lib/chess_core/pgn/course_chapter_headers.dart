/// Chapter titles carried in game headers, the way Chessable course exports
/// encode them: every game titles its chapter in one player header and its
/// variation in the other, with `[Result "*"]` throughout.
///
/// Pure functions over header maps, so the chapter picker, the trainer's
/// chapter grouping, the outline and the line expander all read a course
/// the same way without parsing a move.
library;

import '../../models/repertoire_line.dart' show isModelGameHeaders;

/// Headers a course export has been seen to carry its chapter titles in.
const List<String> kChapterHeaderCandidates = ['White', 'Black', 'Event'];

/// Placeholder values that are never a chapter or line title.
const Set<String> kIgnoredChapterTitles = {
  '',
  '?',
  'me',
  'opponent',
  'white',
  'black',
  'n.n.',
};

/// A course's "Model Games" chapter: whole games shown as illustration.
/// Course exports give them `[Result "*"]` like every other game, so the
/// title is the only thing that says they are not repertoire lines.
final RegExp _modelGamesChapterRe = RegExp(
  r'\bmodel\s*games?\b',
  caseSensitive: false,
);

/// Whether [chapterTitle] names a course's model-games chapter.
bool isModelGamesChapterTitle(String chapterTitle) =>
    _modelGamesChapterRe.hasMatch(chapterTitle);

/// Which header carries the chapter titles of a chapter-titled export —
/// `White`, `Black` or `Event` — or null when none groups the games.
///
/// Course exports disagree: most put the chapter in [White] and the
/// variation title in [Black]; some do the reverse; one puts the chapter
/// in [Event] with the title split over [White] and [Black]. The chapter
/// header is the one whose values come in the fewest contiguous *runs*
/// (a course lists a chapter's lines together, so its chapter header
/// changes forty-odd times in a thousand games while a title header
/// changes on nearly every one). Counting distinct values instead broke on
/// an export whose titles repeat across chapters. White breaks a tie.
String? chapterHeaderKey(List<Map<String, String>> headersPerGame) {
  String? best;
  var bestRuns = 1 << 30;
  for (final key in kChapterHeaderCandidates) {
    final titles = detectHeaderChapters(headersPerGame, key: key);
    if (titles == null) continue;
    final runs = _runs(titles);
    if (runs < bestRuns) {
      best = key;
      bestRuns = runs;
    }
  }
  return best;
}

/// The header that titles a line when [chapterKey] carries the chapter:
/// the other player header, or [White] under an [Event] chapter. [Black]
/// when the file has no chapter structure — this app's own exports put the
/// variation title there.
String titleHeaderKeyFor(String? chapterKey) => switch (chapterKey) {
  'Black' || 'Event' => 'White',
  _ => 'Black',
};

/// How many contiguous groups of equal values [titles] falls into.
int _runs(List<String?> titles) {
  var runs = 0;
  String? previous;
  var first = true;
  for (final title in titles) {
    if (first || title != previous) runs++;
    first = false;
    previous = title;
  }
  return runs;
}

/// Detects chapter titles carried in game headers under [key].
///
/// Returns one chapter name (or null) per game, or null when the file does
/// not look chapter-titled. The guards keep real-game collections (decisive
/// results, player names) and this app's own exports ([White "Me"],
/// [Result "1-0"]) from producing bogus chapters. Callers that do not know
/// the key should ask [chapterHeaderKey] first.
List<String?>? detectHeaderChapters(
  List<Map<String, String>> headersPerGame, {
  String key = 'White',
}) {
  var titled = 0;
  var selfDescribed = false;
  final counts = <String, int>{};
  final chapters = <String?>[];
  for (final headers in headersPerGame) {
    final title = (headers[key] ?? '').trim();
    final result = (headers['Result'] ?? '*').trim();
    final isChapterTitle =
        result == '*' && !kIgnoredChapterTitles.contains(title.toLowerCase());
    chapters.add(isChapterTitle ? title : null);
    if (isChapterTitle) {
      titled++;
      counts[title] = (counts[title] ?? 0) + 1;
    }
    selfDescribed = selfDescribed || isModelGameHeaders(headers);
  }

  // Chapter-style only when titles actually group games: more than one
  // chapter, at least one with multiple games, covering most of the file.
  if (counts.length < 2) return null;
  // ModelGame* tags only exist in this app's own course exports, so a file
  // carrying them needs no guessing — and a small course can legitimately
  // hold one line and one model game.
  if (!selfDescribed && !counts.values.any((c) => c >= 2)) return null;
  if (titled * 2 < headersPerGame.length) return null;
  return chapters;
}
