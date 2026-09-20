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

/// The first [plies] moves of [tree]'s main line, numbered: `1.d4 d5 2.c4`.
/// A line with more moves than that ends in an ellipsis, so a row that shows
/// it says there is more without having to measure the text.
String openingMoves(GameTree tree, {required int plies}) {
  final words = <String>[];
  var siblings = tree.children;
  var first = true;
  while (siblings.isNotEmpty && words.length < plies) {
    final node = siblings.first;
    words.add('${moveNumberLabel(node, startsLine: first)}${node.san}');
    siblings = node.children;
    first = false;
  }
  return siblings.isEmpty ? words.join(' ') : '${words.join(' ')} …';
}
