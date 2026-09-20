import 'game_tree.dart';

/// Merges the forest [b] into [a].
///
/// A move present in both keeps [a]'s place in the list, [a]'s comments and
/// NAGs unless [a] has none, and the merged continuations of both. Moves only
/// in [b] are appended in [b]'s order. So when a chapter's games are folded
/// in file order, the first game fixes the main line and every later game can
/// only add variations, never reorder what is already there.
///
/// Two nodes are the same move when their SAN is equal; both forests hang off
/// the same position, so equal SAN means an equal move and an equal FEN.
///
/// One forest is folded the same way, so a single game that writes the same
/// reply twice — `1. e4 e5 (1... e5 {alt}) 2. Nf3` — still gives one node per
/// move. Two siblings with one SAN would break the one thing the rest of the
/// app relies on: that a line of SAN names and a path through the tree say
/// the same thing, and that the cursor lands where the move is.
///
/// [a] is empty or a forest this function produced, so it plays no move
/// twice; nothing copies it when there is nothing to merge into it.
List<MoveNode> mergeForests(List<MoveNode> a, List<MoveNode> b) {
  if (b.isEmpty) return a;
  if (a.isEmpty && !_playsAMoveTwice(b)) return b;
  final merged = <MoveNode>[];
  for (final incoming in a.followedBy(b)) {
    final i = merged.indexWhere((node) => node.san == incoming.san);
    if (i < 0) {
      merged.add(_folded(incoming));
      continue;
    }
    final existing = merged[i];
    merged[i] = existing.copyWith(
      startingComment: existing.startingComment ?? incoming.startingComment,
      comment: existing.comment ?? incoming.comment,
      nags: existing.nags.isEmpty ? incoming.nags : existing.nags,
      children: mergeForests(existing.children, incoming.children),
    );
  }
  return List.unmodifiable(merged);
}

/// [node] with the moves under it folded, or [node] itself when there was
/// nothing to fold, which is the whole of an ordinary game.
MoveNode _folded(MoveNode node) {
  final children = mergeForests(const [], node.children);
  return identical(children, node.children)
      ? node
      : node.copyWith(children: children);
}

/// Whether [forest] or anything under it gives one move two nodes.
bool _playsAMoveTwice(List<MoveNode> forest) {
  final sans = <String>{};
  for (final node in forest) {
    if (!sans.add(node.san) || _playsAMoveTwice(node.children)) return true;
  }
  return false;
}
