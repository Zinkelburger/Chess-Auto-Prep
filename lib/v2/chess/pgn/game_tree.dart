import 'package:collection/collection.dart';

import '../fen.dart';

/// One move in a game tree and what the PGN said about it.
///
/// Immutable: an edit produces a new tree. `children[0]` is the main
/// continuation; the rest are variations in PGN order. [comment] is the raw
/// text after the move, machine tokens included, so a later save can write it
/// back exactly; `displayComment` in `comment_text.dart` is what a person
/// reads.
final class MoveNode {
  const MoveNode({
    required this.san,
    required this.uci,
    required this.fen,
    this.spelling,
    this.startingComment,
    this.comment,
    this.nags = const [],
    this.children = const [],
  });

  /// Normalised SAN, as dartchess writes it (`Nf3`, `O-O`, `exd6#`). It is
  /// the move's identity: two spellings of one move are one node.
  final String san;

  /// The SAN exactly as the file spelled it, when that is not [san] — `0-0`
  /// for castling, a disambiguation the position does not need, `e8Q` for a
  /// promotion, a missing `+`. Null when the file agreed with [san].
  ///
  /// Writing a game again uses it, so editing one move does not re-spell
  /// every other move in the game.
  final String? spelling;

  /// The same move as `e2e4` / `e7e8q`, for the board's last-move highlight.
  final String uci;

  /// The position after this move.
  final Fen fen;

  /// The comment the file wrote *before* this move rather than after it,
  /// which is how a variation is introduced: `({A note} 1. d4 d5)`. Kept
  /// apart from [comment] because that is where it has to go back.
  ///
  /// Only a move that starts a variation can have one, because `(` is the
  /// only place a file can put a comment that belongs to the move after it:
  /// before the game's first move a comment is the introduction,
  /// [GameTree.rootComment], and anywhere else it reads as the comment on
  /// the move before. Reading never produces one anywhere else; putting one
  /// there makes the game unwritable, which the rewrite gate reports rather
  /// than lets through.
  final String? startingComment;

  final String? comment;

  /// Numeric annotation glyphs, e.g. 1 for `!` and 2 for `?`.
  final List<int> nags;

  final List<MoveNode> children;

  MoveNode copyWith({
    String? startingComment,
    String? comment,
    List<int>? nags,
    List<MoveNode>? children,
  }) => MoveNode(
    san: san,
    uci: uci,
    fen: fen,
    spelling: spelling,
    startingComment: startingComment ?? this.startingComment,
    comment: comment ?? this.comment,
    nags: nags ?? this.nags,
    children: children ?? this.children,
  );

  @override
  String toString() => 'MoveNode($san, ${children.length} children)';
}

/// Where a node sits in a tree: the child index taken at each depth.
///
/// The root is the empty path. Paths are values, so a cursor survives the
/// tree being replaced by an edited copy as long as the shape above it holds.
final class NodePath {
  const NodePath.root() : indexes = const [];

  NodePath.of(Iterable<int> indexes) : indexes = List.unmodifiable(indexes);

  final List<int> indexes;

  bool get isRoot => indexes.isEmpty;

  NodePath get parent =>
      isRoot ? this : NodePath.of(indexes.take(indexes.length - 1));

  NodePath child(int index) => NodePath.of([...indexes, index]);

  NodePath get mainChild => child(0);

  /// Whether [other] is this path or a move somewhere before it on the way
  /// here: the root leads to every path.
  bool startsWith(NodePath other) =>
      other.indexes.length <= indexes.length &&
      const ListEquality<int>().equals(
        indexes.sublist(0, other.indexes.length),
        other.indexes,
      );

  @override
  bool operator ==(Object other) =>
      other is NodePath &&
      const ListEquality<int>().equals(indexes, other.indexes);

  @override
  int get hashCode => const ListEquality<int>().hash(indexes);

  @override
  String toString() => 'NodePath(${indexes.join('/')})';
}

/// The moves of one game, or of a whole chapter merged, from [rootFen].
final class GameTree {
  const GameTree({
    required this.rootFen,
    this.rootComment,
    this.children = const [],
  });

  final Fen rootFen;

  /// Comment before the first move, if any.
  final String? rootComment;

  final List<MoveNode> children;

  bool get isEmpty => children.isEmpty;

  /// The node at [path], or null when the path leaves the tree. The root is
  /// not a node, so the root path also returns null.
  MoveNode? nodeAt(NodePath path) {
    if (path.isRoot) return null;
    return lineTo(path).lastOrNull;
  }

  /// The nodes from the first move down to [path], inclusive; empty for the
  /// root and for a path that leaves the tree.
  List<MoveNode> lineTo(NodePath path) {
    final line = <MoveNode>[];
    var siblings = children;
    for (final index in path.indexes) {
      if (index >= siblings.length) return const [];
      final node = siblings[index];
      line.add(node);
      siblings = node.children;
    }
    return line;
  }

  Fen fenAt(NodePath path) => nodeAt(path)?.fen ?? rootFen;

  /// The last node reached by following main continuations from [path].
  NodePath endOfLineFrom(NodePath path) {
    var end = path;
    while (nodeAt(end.mainChild) != null) {
      end = end.mainChild;
    }
    return end;
  }
}
