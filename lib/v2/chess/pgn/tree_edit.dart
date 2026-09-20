import 'package:dartchess/dartchess.dart';

import '../fen.dart';
import 'game_tree.dart';

/// Pure edits over a [GameTree]: every one returns a new tree.
///
/// A chapter's persistent unit is the game, so these run over one game's
/// tree at a time; the chapter's merged tree is built again afterwards from
/// the edited games.

/// The position [fen] describes, or null when the text is not a position
/// a game can be played from.
Position? positionOf(Fen fen) {
  try {
    return Chess.fromSetup(Setup.parseFen(fen.value));
  } on FenException {
    return null;
  } on PositionSetupException {
    return null;
  }
}

/// [move] played from [fen] as a childless node, or null when it is not a
/// legal move there. The SAN comes back as dartchess spells it, so two
/// spellings of one move cannot become two children. Callers that start from
/// text parse it with [positionOf] first; a move is a move however it was
/// written down.
MoveNode? moveNode(Fen fen, Move move) {
  final position = positionOf(fen);
  if (position == null || !position.isLegal(move)) return null;
  final (next, san) = position.makeSan(move);
  return MoveNode(san: san, uci: move.uci, fen: Fen(next.fen));
}

/// The SAN of each move down the main continuation from the root.
List<String> mainlineSans(GameTree tree) {
  final sans = <String>[];
  var siblings = tree.children;
  while (siblings.isNotEmpty) {
    sans.add(siblings.first.san);
    siblings = siblings.first.children;
  }
  return sans;
}

/// Where [sans] leads in [tree], variations included, or null when the tree
/// does not hold that sequence.
NodePath? pathOfSans(GameTree tree, List<String> sans) {
  var path = const NodePath.root();
  var siblings = tree.children;
  for (final san in sans) {
    final index = siblings.indexWhere((node) => node.san == san);
    if (index < 0) return null;
    path = path.child(index);
    siblings = siblings[index].children;
  }
  return path;
}

/// A tree whose only line is [sans] played from [rootFen], stopping at the
/// first move that is not legal.
///
/// The moves carry no comments: a new game written for a branch shares its
/// opening moves with the game it branched from, and that game already
/// carries their comments. Duplicating them would give one move two
/// comments that later drift apart.
GameTree lineTree(Fen rootFen, List<String> sans) {
  final nodes = <MoveNode>[];
  var fen = rootFen;
  for (final san in sans) {
    final move = positionOf(fen)?.parseSan(san);
    final node = move == null ? null : moveNode(fen, move);
    if (node == null) break;
    nodes.add(node);
    fen = node.fen;
  }
  var children = const <MoveNode>[];
  for (final node in nodes.reversed) {
    children = [node.copyWith(children: children)];
  }
  return GameTree(rootFen: rootFen, children: children);
}

/// [tree] with [node] appended to the children of the node at [at].
GameTree withChildAdded(GameTree tree, NodePath at, MoveNode node) =>
    _rebuilt(tree, at.indexes, (children) => [...children, node]);

/// [tree] with the comment of the node at [at] replaced; the root path sets
/// the comment before the first move.
GameTree withComment(GameTree tree, NodePath at, String? comment) {
  if (at.isRoot) {
    return GameTree(
      rootFen: tree.rootFen,
      rootComment: comment,
      children: tree.children,
    );
  }
  final last = at.indexes.last;
  return _rebuilt(tree, at.parent.indexes, (children) {
    if (last >= children.length) return children;
    final out = [...children];
    out[last] = _commented(children[last], comment);
    return out;
  });
}

/// [node] with [comment], which [MoveNode.copyWith] cannot clear.
MoveNode _commented(MoveNode node, String? comment) => MoveNode(
  san: node.san,
  uci: node.uci,
  fen: node.fen,
  startingComment: node.startingComment,
  comment: comment,
  nags: node.nags,
  children: node.children,
);

typedef _ChildEdit = List<MoveNode> Function(List<MoveNode> children);

GameTree _rebuilt(GameTree tree, List<int> indexes, _ChildEdit edit) =>
    GameTree(
      rootFen: tree.rootFen,
      rootComment: tree.rootComment,
      children: _editChildren(tree.children, indexes, edit),
    );

List<MoveNode> _editChildren(
  List<MoveNode> children,
  List<int> indexes,
  _ChildEdit edit,
) {
  if (indexes.isEmpty) return List.unmodifiable(edit(children));
  final index = indexes.first;
  if (index >= children.length) return children;
  final out = [...children];
  out[index] = children[index].copyWith(
    children: _editChildren(children[index].children, indexes.sublist(1), edit),
  );
  return List.unmodifiable(out);
}
