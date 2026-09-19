import 'game_tree.dart';

/// Merges the forest [b] into [a].
///
/// A move present in both keeps [a]'s place in the list, [a]'s comment and
/// NAGs unless [a] has none, and the merged continuations of both. Moves only
/// in [b] are appended in [b]'s order. So when a chapter's games are folded
/// in file order, the first game fixes the main line and every later game can
/// only add variations, never reorder what is already there.
///
/// Two nodes are the same move when their SAN is equal; both forests hang off
/// the same position, so equal SAN means an equal move and an equal FEN.
List<MoveNode> mergeForests(List<MoveNode> a, List<MoveNode> b) {
  if (b.isEmpty) return a;
  if (a.isEmpty) return b;
  final merged = [...a];
  for (final incoming in b) {
    final i = merged.indexWhere((node) => node.san == incoming.san);
    if (i < 0) {
      merged.add(incoming);
      continue;
    }
    final existing = merged[i];
    merged[i] = existing.copyWith(
      comment: existing.comment ?? incoming.comment,
      nags: existing.nags.isEmpty ? incoming.nags : existing.nags,
      children: mergeForests(existing.children, incoming.children),
    );
  }
  return List.unmodifiable(merged);
}
