import 'package:dartchess/dartchess.dart' show Position;

import '../fen.dart';
import 'search_node.dart';

/// How many times a position has to appear on one path before the search
/// calls it a draw.
const int _repetitionsForDraw = 3;

/// How many half-moves without a capture or a pawn move end the game.
const int _halfMovesForDraw = 100;

/// What makes two positions the same for repetition: the piece placement, the
/// side to move, the castling rights and the en-passant square — the first
/// four fields of the FEN.
///
/// The clocks are deliberately left out: a position repeats whatever the
/// half-move counter says. dartchess only writes an en-passant square when
/// the capture is actually legal, so two keys that match really do offer the
/// same moves.
String repetitionKey(Fen fen) => fen.value.split(' ').take(4).join(' ');

/// Why the game is over at [position], or null when it is not.
///
/// [history] holds [repetitionKey] for every position on the path from the
/// search root down to [position], ending with [position]'s own key. History
/// before the root is unknown, so a repetition is only ever counted inside
/// the search: the same position under two different siblings is two
/// different first occurrences, never a repetition of each other.
///
/// The model has both players claim a draw the moment one is available,
/// which is a convention, not a full account of when a player would want to.
/// Checkmate is decided first: a mating move ends the game even if it also
/// completes a third repetition or the hundredth quiet half-move.
TerminalKind? terminalKind(Position position, List<String> history) {
  if (position.isCheckmate) return TerminalKind.checkmate;
  if (position.isStalemate) return TerminalKind.stalemate;
  if (position.isInsufficientMaterial) {
    return TerminalKind.insufficientMaterial;
  }
  if (position.halfmoves >= _halfMovesForDraw) {
    return TerminalKind.fiftyMoveRule;
  }
  final key = history.last;
  final seen = history.where((other) => other == key).length;
  return seen >= _repetitionsForDraw ? TerminalKind.repetition : null;
}
