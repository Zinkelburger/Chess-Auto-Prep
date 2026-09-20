import 'package:dartchess/dartchess.dart';

/// The four pieces a pawn may become, in the order they are enumerated.
const List<Role> _promotionRoles = [
  Role.queen,
  Role.rook,
  Role.bishop,
  Role.knight,
];

/// A legal move, with the name the rest of the search knows it by.
typedef NamedMove = ({NormalMove move, String uci});

/// Every legal move of [position], sorted by [uci].
///
/// Two things are worth saying about the names. A pawn reaching the last rank
/// is four moves, not one — `e7e8q`, `e7e8r`, `e7e8b`, `e7e8n` — because
/// under-promotion is sometimes the only move that wins, and the search
/// refuses to decide that for us. And castling is named the way Stockfish and
/// the opponent model name it, king to its destination (`e1g1`), while
/// dartchess passes it around as king to rook (`e1h1`) so that Chess960
/// works; [uci] is the former and [NamedMove.move] the latter.
///
/// Sorting by name only fixes the order the tree is built and written in; it
/// is not a ranking and the search never takes the first few.
List<NamedMove> legalMovesOf(Position position) {
  final moves = <NamedMove>[];
  for (final entry in position.legalMoves.entries) {
    final from = entry.key;
    final isPawn = position.board.pieceAt(from)?.role == Role.pawn;
    for (final to in entry.value.squares) {
      if (isPawn && (to.rank == Rank.first || to.rank == Rank.eighth)) {
        moves.addAll(_promotions(from, to));
      } else {
        final move = NormalMove(from: from, to: to);
        moves.add((move: move, uci: _standardUci(position, move)));
      }
    }
  }
  return moves..sort((a, b) => a.uci.compareTo(b.uci));
}

Iterable<NamedMove> _promotions(Square from, Square to) => [
  for (final role in _promotionRoles)
    (
      move: NormalMove(from: from, to: to, promotion: role),
      uci: '${from.name}${to.name}${role.letter}',
    ),
];

/// The king lands two files towards the rook it castled with, so a rook on
/// the higher file puts the king on g and one on the lower file puts it on c.
String _standardUci(Position position, NormalMove move) {
  final board = position.board;
  final isCastling =
      board.pieceAt(move.from)?.role == Role.king &&
      board.pieceAt(move.to)?.role == Role.rook &&
      board.pieceAt(move.to)?.color == position.turn;
  if (!isCastling) return move.uci;
  final destination = Square(
    move.to > move.from ? move.from + 2 : move.from - 2,
  );
  return '${move.from.name}${destination.name}';
}
