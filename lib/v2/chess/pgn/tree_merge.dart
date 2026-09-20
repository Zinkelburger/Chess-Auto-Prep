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
List<MoveNode> mergeForests(List<MoveNode> a, List<MoveNode> b) {
  final merged = <MoveNode>[];
  for (final incoming in a.followedBy(b)) {
    _fold(merged, incoming);
  }
  return List.unmodifiable(merged);
}

void _fold(List<MoveNode> merged, MoveNode incoming) {
  final i = merged.indexWhere((node) => node.san == incoming.san);
  if (i < 0) {
    merged.add(
      incoming.copyWith(children: mergeForests(const [], incoming.children)),
    );
    return;
  }
  final existing = merged[i];
  merged[i] = existing.copyWith(
    startingComment: existing.startingComment ?? incoming.startingComment,
    comment: existing.comment ?? incoming.comment,
    nags: existing.nags.isEmpty ? incoming.nags : existing.nags,
    children: mergeForests(existing.children, incoming.children),
  );
}
