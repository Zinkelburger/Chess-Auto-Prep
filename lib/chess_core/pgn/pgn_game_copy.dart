import 'package:dartchess/dartchess.dart';

/// Adopt parsed input without retaining any of the caller's mutable containers.
/// Iterative copying preserves sibling order even for very deep games.
PgnGame<PgnNodeData> copyParsedPgn(PgnGame source) {
  final root = PgnNode<PgnNodeData>();
  final pending = [
    for (final node in source.moves.children.reversed) (node, root),
  ];
  while (pending.isNotEmpty) {
    final (node, parent) = pending.removeLast();
    final copied = PgnChildNode(copyPgnMoveData(node.data));
    parent.children.add(copied);
    for (final child in node.children.reversed) {
      pending.add((child, copied));
    }
  }
  return PgnGame(
    headers: Map.of(source.headers),
    comments: List.of(source.comments),
    moves: root,
  );
}

/// A codec value with its own annotation lists.
PgnNodeData copyPgnMoveData(PgnNodeData data) => PgnNodeData(
  san: data.san,
  comments: data.comments == null ? null : List.of(data.comments!),
  startingComments: data.startingComments == null
      ? null
      : List.of(data.startingComments!),
  nags: data.nags == null ? null : List.of(data.nags!),
);
