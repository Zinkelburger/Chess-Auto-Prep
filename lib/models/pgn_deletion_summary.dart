/// Counts the content removed by a PGN operation, including nested sidelines.
library;

import 'move_tree.dart';
import '../utils/pgn_comment_utils.dart' show commentProse;

class PgnDeletionSummary {
  final int moves;
  final int comments;

  const PgnDeletionSummary(this.moves, this.comments);

  factory PgnDeletionSummary.nodes(Iterable<MoveNode> roots) {
    var moves = 0;
    var comments = 0;
    final pending = roots.toList();
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      moves++;
      for (final text in [node.startingComment, node.comment]) {
        if (commentProse(text ?? '').trim().isNotEmpty) comments++;
      }
      pending.addAll(node.children);
    }
    return PgnDeletionSummary(moves, comments);
  }

  factory PgnDeletionSummary.tree(MoveTree tree) {
    final nodes = PgnDeletionSummary.nodes(tree.roots);
    return PgnDeletionSummary(
      nodes.moves,
      nodes.comments +
          (commentProse(tree.rootComment ?? '').trim().isEmpty ? 0 : 1),
    );
  }

  factory PgnDeletionSummary.variations(MoveTree tree) {
    final roots = <MoveNode>[];
    var siblings = tree.roots;
    while (siblings.isNotEmpty) {
      roots.addAll(siblings.skip(1));
      siblings = siblings.first.children;
    }
    return PgnDeletionSummary.nodes(roots);
  }

  String get description =>
      '$moves ${moves == 1 ? 'move' : 'moves'} and '
      '$comments ${comments == 1 ? 'comment' : 'comments'}';
}
