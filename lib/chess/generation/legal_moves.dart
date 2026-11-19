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
/// works; `uci` is the former and [NamedMove.move] the latter. A king that
/// castles from anywhere but the e-file — a set-up position whose castling
/// rights say so — keeps the king-to-rook name, since where it lands could
/// name an ordinary king move or the square it started on.
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
        moves.add((move: move, uci: searchUci(position, move)));
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

/// Whether the legal [move] is castling: the only legal move dartchess
/// spells as landing on a piece of the side that moves.
bool castlesOntoRook(Position position, NormalMove move) =>
    position.board.bySide(position.turn).has(move.to);

/// The name the search knows the legal [move] by. A king castling from the
/// e-file lands on g for the rook on the higher file and on c for the one on
/// the lower file; every other move keeps its own name.
String searchUci(Position position, NormalMove move) {
  if (move.from.file != File.e || !castlesOntoRook(position, move)) {
    return move.uci;
  }
  final side = move.to > move.from ? CastlingSide.king : CastlingSide.queen;
  return '${move.from.name}${kingCastlesTo(position.turn, side).name}';
}
