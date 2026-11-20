import 'package:dartchess/dartchess.dart';

import '../fen.dart';
import '../position_setup.dart';
import 'comment_text.dart';
import 'game_tree.dart';

/// Pure edits over a [GameTree]: every one returns a new tree.
///
/// A chapter's persistent unit is the game, so these run over one game's
/// tree at a time; the chapter's merged tree is built again afterwards from
/// the edited games.

/// The position [fen] describes, or null when the text is not a position
/// a game can be played from.
///
/// Read with [readSetup], which catches whatever the FEN parser throws, and
/// every throw of the position check is caught too: one stray byte in one
/// game must not take a whole document, or the list of every repertoire,
/// down with it. The caller turns null into a located issue.
Position? positionOf(Fen fen) {
  final setup = readSetup(fen.value);
  if (setup == null) return null;
  try {
    return Chess.fromSetup(setup);
  } on Object {
    return null;
  }
}

/// [move] played from [fen] as a childless node, or null when it is not a
/// legal move there. The SAN comes back as dartchess spells it, so two
/// spellings of one move cannot become two children. Callers that start from
/// text parse it with [positionOf] first; a move is a move however it was
/// written down.
///
/// The UCI is the one reading the move's SAN gives, too: castling is king to
/// rook (`e1h1`), which is how the reader stores `O-O`, even when it came as
/// king to destination (`e1g1`) — a king dropped on g1, a typed `O-O`, an
/// engine's line. The rewrite gate compares each move with the text read
/// back, so a castle kept as `e1g1` would be refused as another move.
MoveNode? moveNode(Fen fen, Move move) {
  final position = positionOf(fen);
  if (position == null || !isLegalMove(position, move)) return null;
  final played = move is NormalMove ? position.normalizeMove(move) : move;
  final (next, san) = position.makeSan(played);
  return MoveNode(san: san, uci: played.uci, fen: Fen(next.fen));
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

/// The SAN of each move down [GameTree.mainLine].
List<String> mainlineSans(GameTree tree) => [
  for (final node in tree.mainLine) node.san,
];

/// Where [sans] leads in [tree], variations included, or null when the tree
/// does not hold that sequence.
NodePath? pathOfSans(GameTree tree, List<String> sans) {
  final path = pathAlong(tree, sans);
  return path.indexes.length == sans.length ? path : null;
}

/// Every path in [tree] whose moves are [sans], in order. A game can play
/// one move twice — `1... e5` on the main line and again as a variation
/// beside it — and each copy is a place those moves are.
List<NodePath> pathsOfSans(GameTree tree, List<String> sans) {
  var paths = [const NodePath.root()];
  for (final san in sans) {
    paths = [
      for (final path in paths)
        for (final (index, node)
            in (path.isRoot ? tree.children : tree.nodeAt(path)!.children)
                .indexed)
          if (node.san == san) path.child(index),
    ];
    if (paths.isEmpty) break;
  }
  return paths;
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
///
/// dartchess throws a `RangeError` rather than answering null for a few
/// words that are no move at all (`-`, `x`, `N`, an empty word), and a
/// hand-edited `// Root:` heading can hold any of them.
(MoveNode, Position)? replayed(Position position, String san) {
  if (san == nullMoveSan) return nullMovePlayed(position, spelling: san);
  final move = parseLegalSan(position, san);
  if (move == null) return null;
  final (next, spelled) = position.makeSanUnchecked(move);
  return (MoveNode(san: spelled, uci: move.uci, fen: fenOf(next)), next);
}

/// The legal move [san] names in [position], or null when it names none.
///
/// dartchess answers an unplayable move with null for most spellings and
/// with a `RangeError` for a few — it reads the first character of a SAN it
/// has already cut annotations off, so a token like `xe4` leaves it with
/// nothing to read. It also takes a pawn reaching the last rank without a
/// promotion piece, which no game can play. A move nobody can play is a move
/// nobody can play; the caller reports it either way.
Move? parseLegalSan(Position position, String san) {
  try {
    final move = position.parseSan(san);
    return move == null || _missingPromotion(position, move) ? null : move;
  } on Object {
    return null;
  }
}

/// Whether [move] — an engine's, the board's, a stored line's — can be
/// played in [position]. dartchess says yes to a pawn reaching the last rank
/// with no promotion piece; that move is not legal here.
bool isLegalMove(Position position, Move move) =>
    !_missingPromotion(position, move) && position.isLegal(move);

bool _missingPromotion(Position position, Move move) =>
    move is NormalMove &&
    move.promotion == null &&
    SquareSet.backranks.has(move.to) &&
    position.board.pawns.has(move.from);

/// [tree] with [node] appended to the children of the node at [at].
GameTree withChildAdded(GameTree tree, NodePath at, MoveNode node) =>
    _withMoveEdit(tree, at, (children) => [...children, node]);

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
    _withMoveEdit(tree, parent, (children) {
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

GameTree _withMoveEdit(GameTree tree, NodePath at, _ChildEdit edit) {
  final line = tree.lineTo(at);
  if (!at.isRoot && line.isEmpty) return tree;
  final children = line.lastOrNull?.children ?? tree.children;
  final next = edit(children);
  if (identical(next, children)) return tree;

  // A changed variation belongs to the player, even if later edits bring
  // it back to the number of plies the review wrote.
  for (final (index, node) in line.indexed) {
    final comment = node.comment;
    if (comment == null || !reviewLineMarker.hasMatch(comment)) continue;
    final head = NodePath.of(at.indexes.take(index + 1));
    tree = withComment(tree, head, withoutReviewLineMarker(comment));
  }
  return _rebuilt(tree, at.indexes, (_) => next);
}

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
