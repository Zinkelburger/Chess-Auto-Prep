import 'package:dartchess/dartchess.dart' show Side;

import '../pgn/move_label.dart' show numberedMoves;
import '../repertoire_index.dart';
import 'played_game.dart';

/// One repertoire file the book check reads: where it is, what it is
/// called and what it plays.
final class BookFile {
  const BookFile({required this.path, required this.name, required this.index});

  final String path;
  final String name;
  final RepertoireIndex index;
}

/// A position in a repertoire file: the file, and the moves from its start
/// that reach it there.
final class BookPlace {
  const BookPlace(this.file, this.sans);

  final BookFile file;
  final List<String> sans;
}

/// One move the book plays at a position, over every file of the side.
final class BookMove {
  const BookMove({required this.label, required this.lines, required this.at});

  /// Numbered as it would start a line: `6.Bg5`.
  final String label;

  /// How many lines of the books go through it.
  final int lines;

  /// The move in the file with the most lines through it, for how that
  /// file goes on.
  final IndexedMove at;
}

/// What the user's books say about one of their games.
sealed class BookVerdict {
  const BookVerdict();
}

/// The user has no repertoire for the side they played.
final class NoBook extends BookVerdict {
  const NoBook();
}

/// The game left every book before a full move was played: another
/// opening, not a mistake.
final class OtherOpening extends BookVerdict {
  const OtherOpening();
}

/// Every move of the game is in the book.
final class InBookThroughout extends BookVerdict {
  const InBookThroughout(this.place);

  /// Where the game's last position is in the book.
  final BookPlace place;
}

/// Who took the game out of the book.
enum Deviation {
  /// The user played a move their book does not.
  mine,

  /// The opponent played a move the book has no answer for.
  theirs,

  /// The book has nothing past this position: the preparation ran out.
  bookEnded,
}

/// The game was in the book until [ply], its first move past it.
final class LeftBook extends BookVerdict {
  const LeftBook({
    required this.kind,
    required this.ply,
    required this.played,
    required this.playedUci,
    required this.book,
    required this.place,
    required this.position,
  });

  final Deviation kind;

  /// The game's move that went past the book, counting from zero: also how
  /// many of its moves were in it.
  final int ply;

  /// That move, numbered: `6.f3`.
  final String played;
  final String playedUci;

  /// What the books play instead, most lines first; empty where they end.
  final List<BookMove> book;

  /// Where the position before [played] is in the book.
  final BookPlace place;

  /// That position, as a [Fen.position] key.
  final String position;

  /// Games that left the book the same way have the same key: the same
  /// move, or the same place where the book ends.
  String get sameWay => kind == Deviation.bookEnded
      ? '${kind.name} $position'
      : '${kind.name} $position $playedUci';
}

/// Fewer moves than this in the book is another opening, not a deviation:
/// the first move pair has to match before a game counts as in the book.
const bookEntryPlies = 2;

/// Reads [game] against the user's books of the side they played.
///
/// The game is in the book up to the *last* of its positions any book
/// reaches, by any move order: a game that leaves the book and comes back
/// by transposition is judged from the fork it never returned from. The
/// move played from that position is the verdict: the user's own move the
/// book does not play, the opponent's the book has no answer for, or any
/// move where the book has nothing more to say.
///
/// Example: with a book `1.e4 c5 2.Nf3 d6 3.d4`, the game `1.e4 c5 2.Nf3
/// Nc6 3.d4` left at ply 3 with the opponent's `2...Nc6`, while `1.e4 c5
/// 2.Nc3` left at ply 2 with the user's own `2.Nc3`, the book's `2.Nf3`
/// beside it.
BookVerdict checkGame(PlayedGame game, List<BookFile> books) {
  final mine = [
    for (final file in books)
      if (file.index.side == game.side) file,
  ];
  if (mine.isEmpty) return const NoBook();
  final last = _lastInBook(game.positions, mine);
  if (last < bookEntryPlies) return const OtherOpening();
  final position = game.positions[last];
  final place = _placeOf(position, mine);
  if (last == game.moves.length) return InBookThroughout(place);
  final book = _bookMoves(position, mine);
  final move = game.moves[last];
  return LeftBook(
    kind: book.isEmpty
        ? Deviation.bookEnded
        : _toMove(position) == game.side
        ? Deviation.mine
        : Deviation.theirs,
    ply: last,
    played: move.label,
    playedUci: move.uci,
    book: book,
    place: place,
    position: position,
  );
}

/// The index of the last position of [positions] any of [books] reaches,
/// or -1 when none does.
int _lastInBook(List<String> positions, List<BookFile> books) {
  for (var i = positions.length - 1; i >= 0; i--) {
    if (books.any((file) => file.index.movesAt(positions[i]) != null)) {
      return i;
    }
  }
  return -1;
}

/// The file with the most lines through [position], or the first that
/// reaches it where every one ends there.
BookPlace _placeOf(String position, List<BookFile> books) {
  BookFile? best;
  var most = -1;
  for (final file in books) {
    final moves = file.index.movesAt(position);
    if (moves == null) continue;
    final lines = moves.values.fold(0, (sum, move) => sum + move.lines);
    if (lines > most) (best, most) = (file, lines);
  }
  final file = best!;
  return BookPlace(file, file.index.into(position)?.sans ?? const []);
}

/// Every move any of [books] plays at [position], each once, most lines
/// first.
List<BookMove> _bookMoves(String position, List<BookFile> books) {
  final byUci = <String, List<IndexedMove>>{};
  for (final file in books) {
    for (final move
        in file.index.movesAt(position)?.values ?? const <IndexedMove>[]) {
      (byUci[move.node.uci] ??= []).add(move);
    }
  }
  final moves = [
    for (final seen in byUci.values)
      BookMove(
        label: numberedMoves([seen.first.node]),
        lines: seen.fold(0, (sum, move) => sum + move.lines),
        at: seen.reduce((a, b) => b.lines > a.lines ? b : a),
      ),
  ]..sort((a, b) => b.lines.compareTo(a.lines));
  return List.unmodifiable(moves);
}

/// Whose move it is in a [Fen.position] key.
Side _toMove(String position) =>
    position.split(' ')[1] == 'b' ? Side.black : Side.white;
