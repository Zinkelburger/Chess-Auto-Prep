import 'game_tree.dart';

/// The number printed before a move: `5.` for White, `5...` for a Black move
/// that starts a line, nothing for a Black move that follows its White move.
///
/// Read off the position *after* the move: if Black is to move, White just
/// moved and the full-move number is still this move's; if White is to move,
/// Black just moved and the counter has already advanced.
String moveNumberLabel(MoveNode node, {required bool startsLine}) {
  final fen = node.fen;
  if (!fen.whiteToMove) return '${fen.fullMove}.';
  return startsLine ? '${fen.fullMove - 1}...' : '';
}
