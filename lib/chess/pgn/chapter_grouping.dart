/// Which chapter each game of a file belongs to, when the file has chapters.
///
/// A Lichess study export titles every game with `ChapterName`; a Chessable
/// course titles a chapter's games alike in one player header. Anything else
/// is one chapter. The import writes each title into its lines'
/// `[ChapterName]`, and the PGN Viewer lists a file's games under the same
/// titles, so both read them here.
///
/// Pure: the games' headers in, one title per game out.
library;

import 'game_text.dart';

/// The chapter a game belongs to when a file does not sort its games into
/// any, and the name of a chapter whose title is empty.
const defaultChapterTitle = 'Main';

/// How a file's games fall into chapters.
final class ChapterGrouping {
  const ChapterGrouping({
    required this.titles,
    required this.chapterKey,
    required this.titleKey,
  });

  /// One chapter title per game, in file order. Every game has one: a game
  /// with no title of its own goes with the chapter before it.
  final List<String> titles;

  /// The header the chapters are titled in, or null when there are none and
  /// every title is [defaultChapterTitle].
  final String? chapterKey;

  /// The header a line is titled in: where a sideline's branch label goes.
  final String titleKey;

  bool get hasChapters => chapterKey != null;
}

/// How the games whose headers are [headers] fall into chapters.
ChapterGrouping groupChapters(List<List<PgnHeader>> headers) {
  final games = [for (final header in headers) _Game(header)];
  if (games.any((game) => (game.tag('ChapterName') ?? '').trim().isNotEmpty)) {
    return ChapterGrouping(
      titles: _grouped(games, (game) => game.tag('ChapterName')?.trim()),
      chapterKey: 'ChapterName',
      titleKey: 'Black',
    );
  }
  final chapterKey = _courseChapterKey(games);
  if (chapterKey != null) {
    return ChapterGrouping(
      titles: _grouped(games, (game) => _courseTitle(game, chapterKey)),
      chapterKey: chapterKey,
      titleKey: _titleKeyFor(chapterKey),
    );
  }
  return ChapterGrouping(
    titles: List.filled(games.length, defaultChapterTitle),
    chapterKey: null,
    titleKey: 'Black',
  );
}

final class _Game {
  const _Game(this.header);

  final List<PgnHeader> header;

  String? tag(String key) => tagValue(header, key);

  /// A game with a result is somebody's finished game, never a course's
  /// titled line.
  bool get isComplete {
    final result = (tag('Result') ?? '*').trim();
    return result.isNotEmpty && result != '*';
  }
}

/// Each game's title; a game with no title goes with the chapter made last,
/// or into the default one when it comes first.
List<String> _grouped(List<_Game> games, String? Function(_Game) titleOf) {
  final seen = <String>{};
  final titles = <String>[];
  String? last;
  for (final game in games) {
    var title = titleOf(game);
    if (title == null || title.isEmpty) title = last ?? defaultChapterTitle;
    if (seen.add(title)) last = title;
    titles.add(title);
  }
  return titles;
}

/// The headers a course export has been seen to carry its chapter titles in.
const _chapterHeaderCandidates = ['White', 'Black', 'Event'];

/// Placeholder values that are never a chapter or line title.
const _placeholderTitles = {
  '',
  '?',
  'me',
  'opponent',
  'white',
  'black',
  'n.n.',
  'repertoire line',
  'edited line',
  'training',
};

/// Whether [title] is a placeholder a file writes where it names nothing:
/// `?`, `White`, `Repertoire line` and the like.
bool isPlaceholderTitle(String title) =>
    _placeholderTitles.contains(title.trim().toLowerCase());

/// Which header carries the chapter titles of a chapter-titled export, or
/// null when none groups the games.
///
/// Course exports disagree: most put the chapter in `White` and the
/// variation title in `Black`; some the reverse; one puts the chapter in
/// `Event`. The chapter header is the one whose values come in the fewest
/// contiguous runs — a course lists a chapter's lines together, so its
/// chapter header changes forty times in a thousand games while a title
/// header changes on nearly every one. `White` breaks a tie.
String? _courseChapterKey(List<_Game> games) {
  String? best;
  var bestRuns = 1 << 30;
  for (final key in _chapterHeaderCandidates) {
    final titles = _chapterTitles(games, key);
    if (titles == null) continue;
    final runs = _runs(titles);
    if (runs < bestRuns) {
      best = key;
      bestRuns = runs;
    }
  }
  return best;
}

/// One title (or null) per game under [key], or null when the file does not
/// look chapter-titled: more than one title, at least one shared by several
/// games, and most games titled. That keeps a collection of real games with
/// player names from turning into one chapter per player.
List<String?>? _chapterTitles(List<_Game> games, String key) {
  final counts = <String, int>{};
  final titles = <String?>[];
  var titled = 0;
  for (final game in games) {
    final title = _courseTitle(game, key);
    titles.add(title);
    if (title == null) continue;
    titled++;
    counts[title] = (counts[title] ?? 0) + 1;
  }
  if (counts.length < 2) return null;
  if (!counts.values.any((count) => count >= 2)) return null;
  if (titled * 2 < games.length) return null;
  return titles;
}

String? _courseTitle(_Game game, String key) {
  final title = (game.tag(key) ?? '').trim();
  if (game.isComplete || isPlaceholderTitle(title)) {
    return null;
  }
  return title;
}

/// The header that titles a line when [chapterKey] carries the chapter: the
/// other player header, or `White` under an `Event` chapter.
String _titleKeyFor(String chapterKey) => switch (chapterKey) {
  'Black' || 'Event' => 'White',
  _ => 'Black',
};

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
