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

/// [plies] moves of [tree]'s main line, numbered, beginning at the move
/// after [skip]: `1.d4 d5 2.c4`, or `…7.Nge2 Nc6` for a line shown from
/// where it left another. An ellipsis stands for the moves not shown, at
/// either end, so a row says there is more without having to measure text.
String movesFrom(GameTree tree, {required int plies, int skip = 0}) {
  final words = <String>[];
  var siblings = tree.children;
  var at = 0;
  while (siblings.isNotEmpty && words.length < plies) {
    final node = siblings.first;
    if (at >= skip) {
      words.add(
        '${moveNumberLabel(node, startsLine: words.isEmpty)}${node.san}',
      );
    }
    siblings = node.children;
    at++;
  }
  final start = skip > 0 ? '…' : '';
  return siblings.isEmpty
      ? '$start${words.join(' ')}'
      : '$start${words.join(' ')} …';
}
