/// Which side a PGN somebody else wrote is a repertoire for, when it does
/// not say: read off the shape of its lines. Pure.
library;

import 'package:dartchess/dartchess.dart' show Side;

import 'game_tree.dart';

/// Fewer lines than this and the shape of the tree means nothing.
const _minLinesForBranching = 8;
const _minLinesForLastMove = 4;

/// The side the lines in [trees] appear to train, or null when they do not
/// say clearly. [trees] are the lines of an import that have moves and are
/// not whole games.
///
/// A repertoire answers each opponent move with one move of its own and
/// covers many opponent replies, so the side that branches is the opponent.
/// Failing that, a line normally ends on the move the reader is meant to
/// know. Neither is trusted on a handful of lines or a thin margin: asking
/// the user is better than a confident wrong answer.
Side? inferredRepertoireSide(List<GameTree> trees) {
  if (trees.length < _minLinesForLastMove) return null;
  return _fromBranching(trees) ?? _fromLastMoves(trees);
}

Side? _fromBranching(List<GameTree> trees) {
  if (trees.length < _minLinesForBranching) return null;
  final nextMoves = <String, Set<String>>{};
  final toMove = <String, bool>{};
  for (final tree in trees) {
    var fen = tree.rootFen;
    var siblings = tree.children;
    while (siblings.isNotEmpty) {
      final node = siblings.first;
      nextMoves.putIfAbsent(fen.position, () => {}).add(node.san);
      toMove[fen.position] = fen.whiteToMove;
      fen = node.fen;
      siblings = node.children;
    }
  }
  var white = 0;
  var black = 0;
  for (final MapEntry(key: position, value: moves) in nextMoves.entries) {
    if (moves.length < 2) continue;
    if (toMove[position]!) {
      white++;
    } else {
      black++;
    }
  }
  if (white + black < 4) return null;
  if (white >= 3 * black) return Side.black;
  if (black >= 3 * white) return Side.white;
  return null;
}

Side? _fromLastMoves(List<GameTree> trees) {
  var endsOnWhite = 0;
  for (final tree in trees) {
    var fen = tree.rootFen;
    var siblings = tree.children;
    while (siblings.isNotEmpty) {
      fen = siblings.first.fen;
      siblings = siblings.first.children;
    }
    // After White's move it is Black to move.
    if (!fen.whiteToMove) endsOnWhite++;
  }
  final total = trees.length;
  if (endsOnWhite * 4 >= total * 3) return Side.white;
  if ((total - endsOnWhite) * 4 >= total * 3) return Side.black;
  return null;
}
