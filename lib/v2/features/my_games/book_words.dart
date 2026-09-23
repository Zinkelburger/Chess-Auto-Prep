import 'package:dartchess/dartchess.dart' show Side;

import '../../chess/book/book_check.dart';
import '../../chess/book/played_game.dart';
import 'game_book.dart';

/// What the screen says about a checked game, in one place, so the list and
/// the Book tab cannot word the same verdict two ways.

/// The one line a game's row says about its book.
String verdictLine(CheckedGame checked) => switch (checked.verdict) {
  NoBook() => 'No ${sideName(checked.game.side)} repertoire',
  OtherOpening() => 'Another opening',
  InBookThroughout() => 'In book to the end',
  LeftBook(kind: Deviation.mine, :final played, :final book) =>
    'You left book: $played (book ${book.first.label})',
  LeftBook(kind: Deviation.theirs, :final played) =>
    'Not in your book: $played',
  LeftBook(kind: Deviation.bookEnded, :final ply) =>
    'Book ended after ${checked.game.moves[ply - 1].label}',
};

/// Whether a search for [query], trimmed and in lower case, finds
/// [checked]: by its opponent or date, or by what its row says about its
/// book, move included.
bool matchesSearch(CheckedGame checked, String query) => [
  checked.game.searchText,
  verdictLine(checked).toLowerCase(),
].any((text) => text.contains(query));

/// A row's short form of the verdict: the move it is about, when there is
/// one, and a few words — `6.f3` `left book` — so a narrow column still
/// shows the move.
(String, String) verdictTag(CheckedGame checked) => switch (checked.verdict) {
  NoBook() => ('', 'no ${sideName(checked.game.side)} book'),
  OtherOpening() => ('', 'another opening'),
  InBookThroughout() => ('', 'in book to the end'),
  LeftBook(kind: Deviation.mine, :final played) => (played, 'left book'),
  LeftBook(kind: Deviation.theirs, :final played) => (played, 'not in book'),
  LeftBook(kind: Deviation.bookEnded, :final ply) => (
    checked.game.moves[ply - 1].label,
    'book ended',
  ),
};

/// `White`, `Black`.
String sideName(Side side) => side == Side.white ? 'White' : 'Black';

/// `Won`, `Lost`, `Drawn`, or nothing for a game with no result.
String outcomeWord(GameOutcome outcome) => switch (outcome) {
  GameOutcome.won => 'Won',
  GameOutcome.lost => 'Lost',
  GameOutcome.drawn => 'Drawn',
  GameOutcome.unfinished => '',
};

/// `vs Rival (2105)`.
String opponentLine(PlayedGame game) => game.opponentElo.isEmpty
    ? 'vs ${game.opponent}'
    : 'vs ${game.opponent} (${game.opponentElo})';

/// `vs Rival (2105) · Lost · 2026.09.20`: who, how it went and when.
String gameLine(PlayedGame game) => [
  opponentLine(game),
  outcomeWord(game.outcome),
  game.date,
].where((words) => words.isNotEmpty).join(' · ');

/// The heading of each group of the Openings view.
String deviationHeading(Deviation kind) => switch (kind) {
  Deviation.mine => 'You left book',
  Deviation.theirs => 'Not in your book',
  Deviation.bookEnded => 'Book ended',
};

/// The two lines of a group of the Openings view: the move, or where the
/// book ended, over what the book has there and in which file. [newest] is
/// the game that speaks for the group.
(String, String) wayLines(LeftBook verdict, PlayedGame newest) {
  final file = verdict.place.file.name;
  return switch (verdict.kind) {
    Deviation.bookEnded => (
      'after ${newest.moves[verdict.ply - 1].label}',
      file,
    ),
    Deviation.mine || Deviation.theirs => (
      verdict.played,
      'Book ${verdict.book.map((m) => m.label).join(', ')} · $file',
    ),
  };
}
