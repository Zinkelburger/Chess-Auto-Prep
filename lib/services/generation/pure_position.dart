/// Chess rules and legal actions used by the finite-horizon reference search.
library;

import 'package:dartchess/dartchess.dart';
import '../../chess_core/generation/build_tree_node.dart';
import '../../utils/chess_utils.dart';

/// Promotion pieces in the order their UCI moves are enumerated.
const List<Role> _promotionRoles = [
  Role.queen,
  Role.rook,
  Role.bishop,
  Role.knight,
];

/// Every legal move of [position] as standard UCI, sorted, with each pawn
/// promotion expanded to all four pieces. Sorting fixes the enumeration
/// order that node ids and Fast decisions are committed in.
List<String> pureLegalMoves(Position position) {
  final moves = <String>[];
  for (final entry in position.legalMoves.entries) {
    final piece = position.board.pieceAt(entry.key)!;
    for (final to in entry.value.squares) {
      if (piece.role == Role.pawn && (to ~/ 8 == 0 || to ~/ 8 == 7)) {
        for (final role in _promotionRoles) {
          moves.add(
            moveToStandardUci(
              position,
              NormalMove(from: entry.key, to: to, promotion: role),
            ),
          );
        }
      } else {
        moves.add(toStandardUci(position, entry.key, to));
      }
    }
  }
  return moves..sort();
}

/// Repetition key: piece placement, side to move, castling rights and the
/// en-passant square. The FEN emitted by dartchess drops en-passant targets
/// without a legal capture, so the key already reflects legal availability.
String pureRepetitionKey(Position position) =>
    position.fen.split(' ').take(4).join(' ');

/// The reference model assumes both sides immediately claim available draws.
/// History before the supplied root is unknown; history from it is retained.
/// Checkmate takes precedence over the move-count draw. Returns the terminal
/// value from our perspective (1 win, 0.5 draw, 0 loss), or null when the
/// position is not terminal.
double? pureTerminal(BuildTreeNode node, Position position, bool playAsWhite) {
  if (position.isCheckmate) return node.isWhiteToMove == playAsWhite ? 0 : 1;
  if (position.isStalemate || position.isInsufficientMaterial) return 0.5;
  if (position.halfmoves >= 100) return 0.5;
  final key = pureRepetitionKey(position);
  var count = 0;
  for (BuildTreeNode? p = node; p != null; p = p.parent) {
    final pos = tryParseFen(p.fen);
    if (pos != null && pureRepetitionKey(pos) == key && ++count >= 3) {
      return 0.5;
    }
  }
  return null;
}
