/// Move identity for checking a game against a book.
///
/// Two PGNs can spell the same move differently — `Nf3` and `Nf3+`, `O-O` and
/// `0-0`, `e8=Q` and `e8Q`, `Nbd7` where `Nd7` was enough — and a downloaded
/// game and a hand-written repertoire routinely do. Comparing SAN strings
/// therefore reports deviations that never happened. The key used here is the
/// move itself: each SAN is played in the position it occurs in and reduced to
/// standard UCI, so any legal spelling of a move produces the same key.
///
/// Pure and synchronous; the deviation walker builds its tries with these and
/// the review's book pane matches lines with them.
library;

import 'package:dartchess/dartchess.dart';

import '../../../utils/chess_utils.dart' show moveToStandardUci;

/// The key for [san] played in [position], or null when it is not a legal
/// move there (an unparseable token, or a line that went illegal earlier).
String? moveKey(Position position, String san) {
  final move = position.parseSan(san);
  if (move == null) return null;
  return moveToStandardUci(position, move);
}

/// Keys for [sans] played in order from [start]. Stops at the first move that
/// does not parse, so the result can be shorter than the input: the plies
/// before it are still comparable, the ones after it are not.
List<String> moveKeysFromStart(List<String> sans, {Position? start}) {
  var pos = start ?? Chess.initial;
  final keys = <String>[];
  for (final san in sans) {
    final move = pos.parseSan(san);
    if (move == null) break;
    keys.add(moveToStandardUci(pos, move));
    pos = pos.play(move);
  }
  return keys;
}

/// Whether some root-to-leaf path of [root] — the mainline or any variation —
/// begins with [keys], playing from [start].
bool pgnTreeReaches(
  PgnNode<PgnNodeData> root,
  List<String> keys, {
  Position? start,
}) {
  bool walk(PgnNode<PgnNodeData> node, Position pos, int depth) {
    if (depth == keys.length) return true;
    for (final child in node.children) {
      final move = pos.parseSan(child.data.san);
      if (move == null) continue;
      if (moveToStandardUci(pos, move) != keys[depth]) continue;
      if (walk(child, pos.play(move), depth + 1)) return true;
    }
    return false;
  }

  return walk(root, start ?? Chess.initial, 0);
}
