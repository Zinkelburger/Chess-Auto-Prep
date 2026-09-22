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
///
/// Every throw is caught, not the two named ones: dartchess answers a
/// malformed FEN with `FenException`, with `PositionSetupException` and,
/// from the board parser, with a bare `ArgumentError` — `.NBQKBNR` gives
/// "Invalid argument(s): -2". Which of them came back is not information
/// anybody can use, and one stray byte in one game must not take a whole
/// document, or the list of every repertoire, down with it. The caller
/// turns null into a located issue.
Position? positionOf(Fen fen) {
  try {
    return Chess.fromSetup(Setup.parseFen(fen.value));
  } on Object {
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

/// A ply where nobody moved, played from [position]: the node and the
/// position after it.
///
/// Chessable writes a whole introduction chapter as `{prose} 1. -- *`, and
/// its `Z0` waiting plies carry the variations under them, so a reader that
/// dropped the ply would drop the chapter. Nobody moving advances the clock
/// and the side, and clears the en-passant square: that is the whole rule,
/// and it is done on the position rather than on its FEN so no ply costs a
/// position read back out of text.
(MoveNode, Position) nullMovePlayed(
  Position position, {
  required String spelling,
}) {
  final black = position.turn == Side.black;
  final after = position.copyWith(
    turn: black ? Side.white : Side.black,
    epSquare: null,
    halfmoves: position.halfmoves + 1,
    fullmoves: black ? position.fullmoves + 1 : position.fullmoves,
  );
  return (
    MoveNode(
      san: nullMoveSan,
      spelling: spelling == nullMoveSan ? null : spelling,
      uci: '0000',
      fen: Fen(after.fen),
    ),
    after,
  );
}

/// How this app spells a ply where nobody moved; `Z0`, `0000` and `@@@@`
/// mean the same thing and keep their own spelling.
const nullMoveSan = '--';

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
  final path = pathAlong(tree, sans);
  return path.indexes.length == sans.length ? path : null;
}

/// As far along [sans] as [tree] goes: the whole way when it holds them,
/// else the last move of theirs it has, or the root.
NodePath pathAlong(GameTree tree, List<String> sans) {
  var path = const NodePath.root();
  var siblings = tree.children;
  for (final san in sans) {
    final index = siblings.indexWhere((node) => node.san == san);
    if (index < 0) break;
    path = path.child(index);
    siblings = siblings[index].children;
  }
  return path;
}

/// A tree whose only line is [sans] played from [rootFen], stopping at the
/// first move that cannot be played.
///
/// A ply where nobody moved is one of the moves it can play. `--` is not a
/// SAN any move generator knows, so replaying a line through one used to
/// stop there and throw away everything after it, including the move the
/// user had just made; the game that came out held no moves at all.
///
/// The moves carry no comments: a new game written for a branch shares its
/// opening moves with the game it branched from, and that game already
/// carries their comments. Duplicating them would give one move two
/// comments that later drift apart.
GameTree lineTree(Fen rootFen, List<String> sans) {
  final nodes = <MoveNode>[];
  var position = positionOf(rootFen);
  for (final san in sans) {
    final played = position == null ? null : replayed(position, san);
    if (played == null) break;
    nodes.add(played.$1);
    position = played.$2;
  }
  var children = const <MoveNode>[];
  for (final node in nodes.reversed) {
    children = [node.copyWith(children: children)];
  }
  return GameTree(rootFen: rootFen, children: children);
}

/// [san] played from [position]: the node and the position after it, or
/// null when it is not a move that can be played there.
(MoveNode, Position)? replayed(Position position, String san) {
  if (san == nullMoveSan) return nullMovePlayed(position, spelling: san);
  final move = position.parseSan(san);
  if (move == null) return null;
  final (next, spelled) = position.makeSan(move);
  return (MoveNode(san: spelled, uci: move.uci, fen: Fen(next.fen)), next);
}

/// [tree] with [node] appended to the children of the node at [at].
GameTree withChildAdded(GameTree tree, NodePath at, MoveNode node) =>
    _rebuilt(tree, at.indexes, (children) => [...children, node]);

/// [tree] with the child at [index] of the node at [parent] first among its
/// siblings, the others keeping their order. That is what promoting a
/// variation means inside one game: the first child is the main line.
GameTree withChildFirst(GameTree tree, NodePath parent, int index) =>
    _rebuilt(tree, parent.indexes, (children) {
      if (index <= 0 || index >= children.length) return children;
      return [
        children[index],
        ...children.take(index),
        ...children.skip(index + 1),
      ];
    });

/// [tree] without the child at [index] of the node at [parent], and without
/// everything under it.
GameTree withChildRemoved(GameTree tree, NodePath parent, int index) =>
    _rebuilt(tree, parent.indexes, (children) {
      if (index < 0 || index >= children.length) return children;
      return [...children]..removeAt(index);
    });

/// Where the moves [path] names in [before] are in [after].
///
/// The moves are followed by name, not by their places in the lists: a path
/// is only a route through a particular tree, and the same numbers in a tree
/// an edit has just rearranged can name entirely different moves. A move
/// [after] does not have leaves the path on the deepest move above it that
/// it does have.
NodePath samePathIn(GameTree before, GameTree after, NodePath path) {
  final kept = <int>[];
  var siblings = after.children;
  for (final step in before.lineTo(path)) {
    final index = siblings.indexWhere((node) => node.san == step.san);
    if (index < 0) break;
    kept.add(index);
    siblings = siblings[index].children;
  }
  return NodePath.of(kept);
}

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
  return withNodeChanged(tree, at, (node) => withNodeComment(node, comment));
}

/// [tree] with the node at [at] put through [change]; the root, which is
/// not a move, and a path the tree does not have leave it as it is.
GameTree withNodeChanged(
  GameTree tree,
  NodePath at,
  MoveNode Function(MoveNode node) change,
) {
  if (at.isRoot) return tree;
  final last = at.indexes.last;
  return _rebuilt(tree, at.parent.indexes, (children) {
    if (last >= children.length) return children;
    final out = [...children];
    out[last] = change(children[last]);
    return out;
  });
}

/// [node] with [nags] as its only annotations.
MoveNode withNags(MoveNode node, List<int> nags) => MoveNode(
  san: node.san,
  uci: node.uci,
  fen: node.fen,
  spelling: node.spelling,
  startingComment: node.startingComment,
  comment: node.comment,
  nags: List.unmodifiable(nags),
  children: node.children,
);

/// [node] with [comment], which [MoveNode.copyWith] cannot clear.
MoveNode withNodeComment(MoveNode node, String? comment) => MoveNode(
  san: node.san,
  uci: node.uci,
  fen: node.fen,
  spelling: node.spelling,
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
