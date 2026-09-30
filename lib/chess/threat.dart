import 'fen.dart';
import 'pgn/tree_edit.dart';

/// The position the side not to move would face if it were its turn — what
/// it threatens: the same board with the turn passed.
///
/// It is a ply where nobody moved ([nullMovePlayed]): en passant goes,
/// because only the side that was to move could have taken it, and the
/// counters move on as for any move. There is no threat to show in check,
/// where passing is no answer, or once the game is over; then, and for a
/// FEN no board reads, this is null. A position a board reads never has the
/// side not to move in check, so the passed one is always legal.
///
/// After 1.e4, `…/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1` becomes
/// `…/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 1 2`: White's best move there is
/// what White threatens.
Fen? threatFen(Fen fen) {
  final position = positionOf(fen);
  if (position == null || position.isCheck || position.isGameOver) {
    return null;
  }
  final (passed, _) = nullMovePlayed(position, spelling: nullMoveSan);
  return passed.fen;
}
