/// Chess rules and legal actions used by the finite-horizon reference search.
library;

import 'package:dartchess/dartchess.dart';
import '../../models/build_tree_node.dart';
import '../../utils/chess_utils.dart';

List<String> pureLegalMoves(Position position) {
  final moves = <String>[];
  for (final entry in position.legalMoves.entries) {
    final piece = position.board.pieceAt(entry.key)!;
    for (final to in entry.value.squares) {
      if (piece.role == Role.pawn && (to ~/ 8 == 0 || to ~/ 8 == 7)) {
        for (final role in [Role.queen, Role.rook, Role.bishop, Role.knight]) {
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

/// FEN emitted by dartchess removes en-passant targets without a legal capture.
String pureRepetitionKey(Position position) =>
    position.fen.split(' ').take(4).join(' ');

/// The reference model assumes both sides immediately claim available draws.
/// History before the supplied root is unknown; history from it is retained.
/// Checkmate takes precedence over the move-count draw.
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
