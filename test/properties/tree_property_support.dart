/// Seeded game generators and structural dumps for the opening-tree property
/// tests.
///
/// Move generation comes from `test/support/props.dart`; what is added here is
/// tree-shaped: whole PGN games with variations, `[FEN]` chapters, and move
/// orders that transpose into one another, plus the total renderings two trees
/// are compared by. Every input is a real game (dartchess plays every move),
/// and every loop is seeded, so a failure reproduces from the seed printed in
/// the reason string.
library;

import 'dart:math';

import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:dartchess/dartchess.dart';

import '../support/props.dart' show legalMovesOf;

// ---------------------------------------------------------------------------
// Generating games
// ---------------------------------------------------------------------------

/// One move of a generated game tree; [children] holds the mainline first and
/// then the variations, exactly as a PGN RAV list does.
class GameNode {
  GameNode(this.san);

  final String san;
  final List<GameNode> children = [];
}

/// A random legal line of up to [maxPlies] plies from [from].
List<String> randomLine(Random rng, {int maxPlies = 10, Position? from}) {
  var pos = from ?? Chess.initial;
  final sans = <String>[];
  for (var i = 0; i < maxPlies; i++) {
    if (pos.isGameOver) break;
    final moves = legalMovesOf(pos);
    if (moves.isEmpty) break;
    final (next, san) = pos.makeSan(moves[rng.nextInt(moves.length)]);
    pos = next;
    sans.add(san);
  }
  return sans;
}

/// A random legal game *tree*: the first child of each node is the mainline,
/// later children are RAVs. [branch] is the chance of a sideline at a node.
List<GameNode> randomGameTree(
  Random rng,
  Position pos, {
  int depth = 0,
  int maxDepth = 6,
  double branch = 0.4,
}) {
  if (depth >= maxDepth || pos.isGameOver) return const [];
  final moves = legalMovesOf(pos)..shuffle(rng);
  if (moves.isEmpty) return const [];
  var count = 1;
  if (rng.nextDouble() < branch) count++;
  if (rng.nextDouble() < branch * 0.4) count++;
  final out = <GameNode>[];
  for (var i = 0; i < count && i < moves.length; i++) {
    final (next, san) = pos.makeSan(moves[i]);
    final node = GameNode(san);
    node.children.addAll(
      randomGameTree(
        rng,
        next,
        depth: depth + 1,
        maxDepth: maxDepth,
        // Sidelines branch less, so a game tree stays game-shaped.
        branch: i == 0 ? branch : branch * 0.3,
      ),
    );
    out.add(node);
  }
  return out;
}

/// PGN movetext for a generated game tree, numbering every ply so a variation
/// that starts on Black's move is unambiguous.
String movetextOf(List<GameNode> children, int ply) {
  if (children.isEmpty) return '';
  final buffer = StringBuffer();
  final mainline = children.first;
  buffer.write(ply.isEven ? '${ply ~/ 2 + 1}. ' : '${ply ~/ 2 + 1}... ');
  buffer.write('${mainline.san} ');
  for (var i = 1; i < children.length; i++) {
    buffer.write('( ${movetextOf([children[i]], ply)}) ');
  }
  buffer.write(movetextOf(mainline.children, ply + 1));
  return buffer.toString();
}

/// A one-game PGN string.
String pgnOf(
  List<GameNode> moves, {
  String result = '*',
  String? fen,
  int startPly = 0,
  String event = 'Property',
}) {
  final buffer = StringBuffer()
    ..writeln('[Event "$event"]')
    ..writeln('[White "Me"]')
    ..writeln('[Black "Opponent"]')
    ..writeln('[Result "$result"]');
  if (fen != null) buffer.writeln('[FEN "$fen"]');
  buffer.writeln();
  buffer.writeln('${movetextOf(moves, startPly)}$result');
  return buffer.toString();
}

/// A one-game PGN for a straight line of SANs.
String pgnOfLine(List<String> sans, {String result = '*', String? fen}) {
  GameNode? head;
  GameNode? tail;
  for (final san in sans) {
    final node = GameNode(san);
    if (head == null) {
      head = node;
    } else {
      tail!.children.add(node);
    }
    tail = node;
  }
  return pgnOf(head == null ? const [] : [head], result: result, fen: fen);
}

/// Move sets whose orders all commute, so every interleaving of a shuffled
/// [transposingWhiteMoves] with a shuffled [transposingBlackMoves] is a legal
/// game reaching one and the same position.
const transposingWhiteMoves = ['d4', 'c4', 'Nf3', 'g3'];
const transposingBlackMoves = ['Nf6', 'e6', 'd5', 'c6'];

List<String> interleave(List<String> white, List<String> black) => [
  for (var i = 0; i < white.length; i++) ...[white[i], black[i]],
];

/// A random legal move order reaching the transposition target position.
List<String> randomTransposingOrder(Random rng) => interleave(
  List.of(transposingWhiteMoves)..shuffle(rng),
  List.of(transposingBlackMoves)..shuffle(rng),
);

// ---------------------------------------------------------------------------
// Folding games into a tree — the app's own merge operation
// ---------------------------------------------------------------------------

/// Fold one PGN game into [tree] exactly the way the app's tree builder does.
void foldGame(OpeningTree tree, String pgnText, {int maxDepth = 30}) {
  OpeningTreeBuilder.addGame(
    tree,
    PgnGame.parsePgn(pgnText),
    usernameLower: '',
    userIsWhite: null,
    maxDepth: maxDepth,
    strictPlayerMatching: false,
  );
}

/// Merge [pgns] into one tree the way the app's batch builders do — via
/// [OpeningTreeBuilder.addGames], which orders the fold so a `[FEN]` chapter
/// lands after whatever reaches its start position.
///
/// Use [foldGame] directly to test the incremental path (one game at a time,
/// as a caller that cannot batch would).
OpeningTree treeFrom(Iterable<String> pgns, {int maxDepth = 30}) {
  final tree = OpeningTree();
  OpeningTreeBuilder.addGames(
    tree,
    pgns.map(PgnGame.parsePgn),
    usernameLower: '',
    userIsWhite: null,
    maxDepth: maxDepth,
    strictPlayerMatching: false,
  );
  return tree;
}

// ---------------------------------------------------------------------------
// Structural views used for comparing two trees
// ---------------------------------------------------------------------------

/// Every node of [tree], root first, in child-insertion order.
List<OpeningTreeNode> allNodes(OpeningTree tree) {
  final out = <OpeningTreeNode>[];
  void walk(OpeningTreeNode node) {
    out.add(node);
    for (final child in node.children.values) {
      walk(child);
    }
  }

  walk(tree.root);
  return out;
}

/// A total, comparable rendering of a tree: one line per node, holding its
/// path, position, stats and child keys.
///
/// [ordered] keeps child-insertion order and DFS order, which two builds of
/// the same input must reproduce exactly. Order-insensitive comparison
/// (`ordered: false`) is for laws that hold up to the order games arrived in
/// — insertion order legitimately follows arrival order.
String dumpTree(OpeningTree tree, {bool ordered = true}) {
  final lines = <String>[];
  void walk(OpeningTreeNode node, String path) {
    final keys = node.children.keys.toList();
    if (!ordered) keys.sort();
    lines.add(
      '$path|${normalizeFen(node.fen)}|${node.gamesPlayed}'
      '|${node.wins}|${node.draws}|${node.losses}|${keys.join(",")}',
    );
    for (final entry in node.children.entries) {
      walk(entry.value, '$path/${entry.key}');
    }
  }

  walk(tree.root, '');
  if (!ordered) lines.sort();
  return lines.join('\n');
}

/// Paths and positions only — the tree's shape, with every count dropped.
String dumpShape(OpeningTree tree) {
  final lines = <String>[];
  void walk(OpeningTreeNode node, String path) {
    final keys = node.children.keys.toList()..sort();
    lines.add('$path|${normalizeFen(node.fen)}|${keys.join(",")}');
    for (final entry in node.children.entries) {
      walk(entry.value, '$path/${entry.key}');
    }
  }

  walk(tree.root, '');
  lines.sort();
  return lines.join('\n');
}

/// Every path in a PGN game (mainline and every RAV), as SAN lists.
List<List<String>> allGamePaths(PgnGame<PgnNodeData> game) {
  final out = <List<String>>[];
  void walk(PgnNode<PgnNodeData> node, List<String> path) {
    for (final child in node.children) {
      final next = [...path, child.data.san];
      out.add(next);
      walk(child, next);
    }
  }

  walk(game.moves, const []);
  return out;
}
