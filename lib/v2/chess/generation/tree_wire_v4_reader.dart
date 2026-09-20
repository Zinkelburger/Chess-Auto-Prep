import 'dart:convert';

import 'package:dartchess/dartchess.dart' show Chess, Position, Setup, Side;

import '../fen.dart';
import 'eval.dart';
import 'search_config.dart';
import 'search_node.dart';
import 'sources.dart';
import 'terminal.dart';
import 'tree_wire_v4.dart';
import 'tree_wire_v4_config.dart';

/// What [decodeTreeV4] made of a file.
sealed class TreeReadResult {
  const TreeReadResult();
}

final class TreeDecoded extends TreeReadResult {
  const TreeDecoded({
    required this.root,
    required this.config,
    required this.complete,
  });

  final SearchNode root;
  final SearchConfig config;

  /// The document's `build_complete`: whether the search that wrote it
  /// reached the horizon everywhere.
  final bool complete;
}

/// A tree this search cannot value: an older format, or one of the other
/// algorithms the old app has. [reason] is plain English for the user.
final class TreeUnsupported extends TreeReadResult {
  const TreeUnsupported(this.reason);

  final String reason;
}

/// The file is not a tree, or a node in it is missing something every node
/// must have. [detail] says which.
final class TreeMalformed extends TreeReadResult {
  const TreeMalformed(this.detail);

  final String detail;
}

/// Reads a v4 document, whether the old Dart app or the C builder wrote it.
///
/// Nothing derived is believed: `value_lower`, `value_upper`,
/// `expectimax_value` and `cumulative_probability` are all recomputed from
/// the shape of the tree, because two sources for one fact is how the two
/// disagree. What the file alone can say — the moves, the positions, the
/// evaluations, the opponent's shares and which nodes were expanded — is what
/// is read.
TreeReadResult decodeTreeV4(String json) {
  Object? parsed;
  try {
    parsed = jsonDecode(json);
  } on FormatException catch (error) {
    return TreeMalformed('the file is not JSON: ${error.message}');
  }
  if (parsed is! Map<String, Object?>) {
    return const TreeMalformed('the file is not a JSON object');
  }
  if (parsed['format'] != treeWireFormat) {
    return const TreeMalformed('the file is not a saved opening tree');
  }
  final tree = parsed['tree'];
  if (tree is! Map<String, Object?>) {
    return const TreeMalformed('the file has no tree in it');
  }
  final snapshot = parsed['config'];
  final config = snapshot is Map<String, Object?>
      ? snapshot
      : const <String, Object?>{};
  final unsupported = unsupportedTreeReason(parsed['version'], config, tree);
  if (unsupported != null) return TreeUnsupported(unsupported);
  return _readTree(tree, configFromSnapshot(config), parsed['build_complete']);
}

TreeReadResult _readTree(
  Map<String, Object?> tree,
  SearchConfig config,
  Object? complete,
) {
  final reader = _Reader(
    ourSide: config.side,
    horizonPlies: config.horizonPlies,
  );
  final root = reader.read(tree, 0);
  if (root == null) {
    return reader.refusal ?? const TreeMalformed('the tree could not be read');
  }
  return TreeDecoded(
    root: root,
    config: config,
    // A file written before builds could be interrupted carries no such key,
    // and every tree in one of those was finished.
    complete: complete is bool ? complete : true,
  );
}

/// Deeper than any saved build goes, and shallow enough that reading a node
/// per level cannot exhaust the stack. A document nested past it is not a
/// tree that was searched but one that was generated at this reader.
const int _plyLimit = 512;

/// Rebuilds the tree, one node at a time, and remembers the first thing that
/// stopped it. A node that cannot be read stops the whole document: half a
/// tree is a different tree, and the caller asked for this one.
final class _Reader {
  _Reader({required this.ourSide, required this.horizonPlies});

  final Side ourSide;

  /// Where the search stopped playing and let the engine value the position.
  /// It is the one thing that tells a horizon leaf from an unexpanded one:
  /// the format writes both as a childless node.
  final int horizonPlies;

  /// The first thing that stopped the read, and what the caller is told.
  TreeReadResult? refusal;

  /// The node [json] describes, or null when the document cannot be read.
  ///
  /// A node may carry no evaluation at all. The old builder attaches a
  /// position's whole set of replies before any of them is evaluated, so
  /// every tree a pause, a cancellation or a node budget left behind ends in
  /// nodes that were reached but never scored. That is unfinished work rather
  /// than a broken file: such a node is read as the frontier it is, at the
  /// neutral score the old app's own backup gives it, with the whole [0, 1]
  /// interval still open below it.
  SearchNode? read(Map<String, Object?> json, int depth) {
    if (depth > _plyLimit) {
      _fail(
        'the tree goes deeper than $_plyLimit plies, which no search '
        'reaches; the file nests further than it can mean',
      );
      return null;
    }
    final text = json['fen'];
    if (text is! String || text.isEmpty) {
      // The C builder can be told to leave positions out to save space. That
      // is a smaller file, not a broken one, but every rule here works from
      // the position: which side is to move, whether the game ended and why.
      _refuse(
        const TreeUnsupported(
          'this tree was saved without positions, and the positions are what '
          'it has to be read from; build it again to open it here',
        ),
      );
      return null;
    }
    final fen = Fen(text);
    final white = json['is_white_to_move'];
    final ourTurn =
        (white is bool ? white : fen.whiteToMove) == (ourSide == Side.white);
    final cp = json['engine_eval_cp'];
    // The file reports from the side to move; the search works from ours. A
    // node with no score at all keeps none, so it goes back out unscored.
    final evalForUs = cp is num
        ? Eval(ourTurn ? cp.toInt() : -cp.toInt())
        : null;
    final children = json['children'];
    final terminal = json['terminal_value'];
    if (terminal is num) {
      return _terminal(
        terminal.toDouble(),
        fen,
        evalForUs,
        ourTurn: ourTurn,
        expanded: children is List && children.isNotEmpty,
      );
    }
    if (children is! List || children.isEmpty) {
      return _leaf(fen, evalForUs, depth: depth);
    }
    final edges = _edges(children, depth);
    if (edges == null) return null;
    return _branch(fen, evalForUs, edges, ourTurn: ourTurn);
  }

  /// A childless node. Only an evaluated one at the horizon is settled: an
  /// unevaluated node is where the build stopped, whatever depth it stopped
  /// at, so its value stays provisional and it stays unscored, which is how
  /// it is written out again.
  SearchNode _leaf(Fen fen, Eval? evalForUs, {required int depth}) =>
      evalForUs != null && depth >= horizonPlies
      ? HorizonNode(fen: fen, evalForUs: evalForUs)
      : FrontierNode(fen: fen, evalForUs: evalForUs);

  /// A node the file says the game ended at.
  ///
  /// A finished game is worth a win, a draw or a loss and nothing between,
  /// and a checkmate is always a loss for whoever is to move in it. A value
  /// that says otherwise is not a tree this reader can value, and it is worth
  /// more to the user as a named position than as a number nobody checked.
  ///
  /// A node that both ends the game and has moves after it states two
  /// incompatible things, and no node here can hold both: a finished game
  /// offers no moves, so the subtree would have to go, and the value the
  /// file recorded would have to go with it if the moves stayed. The reader
  /// names the node instead of choosing one of them for the user.
  SearchNode? _terminal(
    double value,
    Fen fen,
    Eval? evalForUs, {
    required bool ourTurn,
    required bool expanded,
  }) {
    if (expanded) {
      _fail(
        'the node at ${fen.value} both ends the game and has moves after it',
      );
      return null;
    }
    if (value != 0 && value != 0.5 && value != 1) {
      _fail(
        'the node at ${fen.value} ends the game worth $value, which is '
        'neither a win, a draw nor a loss',
      );
      return null;
    }
    final kind = _terminalReason(value, fen);
    if (kind == TerminalKind.checkmate && (value == 0) != ourTurn) {
      _fail(
        'the node at ${fen.value} is a checkmate worth $value, which is '
        'not what the side to move there gets',
      );
      return null;
    }
    return TerminalNode(
      fen: fen,
      evalForUs: evalForUs,
      kind: kind,
      ourTurn: ourTurn,
    );
  }

  SearchNode? _branch(
    Fen fen,
    Eval? evalForUs,
    List<_Edge> edges, {
    required bool ourTurn,
  }) {
    if (ourTurn) {
      return OurNode.over(
        fen: fen,
        evalForUs: evalForUs,
        candidates: [
          for (final edge in edges)
            CandidateMove(move: edge.move, child: edge.child),
        ],
      );
    }
    final shares = _sharesOf(edges, fen);
    if (shares == null) return null;
    return OpponentNode.over(
      fen: fen,
      evalForUs: evalForUs,
      replies: [
        for (final edge in edges)
          ReplyMove(
            move: edge.move,
            probability: shares[edge.move.uci]!,
            child: edge.child,
          ),
      ],
    );
  }

  /// What each reply in [edges] is worth as a share of this node, or null
  /// when they cannot be made into shares at all.
  ///
  /// `move_probability` is what the opponent model gave the reply when it was
  /// written, and a file's numbers need not add up to a whole move: a writer
  /// rounds them, a mode that keeps only part of the policy never had the
  /// rest, and a reply that was dropped takes its share with it. An opponent
  /// node is an average over its replies, so the shares are normalised over
  /// the replies the node actually has — by [Policy.sharesOver], the same
  /// normalising the search does when it first asks the model, so a tree read
  /// here and a tree built here weigh a position the one way. Shares that
  /// already make a whole move come back untouched.
  Map<String, double>? _sharesOf(List<_Edge> edges, Fen fen) {
    final stored = <String, double>{};
    for (final edge in edges) {
      if (stored.containsKey(edge.move.uci)) {
        _fail('the node at ${fen.value} plays ${edge.move.san} twice');
        return null;
      }
      stored[edge.move.uci] = edge.probability;
    }
    final shares = Policy(stored).sharesOver(stored.keys);
    if (shares == null) {
      _fail('the replies of the node at ${fen.value} share no weight at all');
      return null;
    }
    if (shares.length != stored.length) {
      _fail(
        'a reply of the node at ${fen.value} was saved with no weight, '
        'and a node cannot be averaged over a move nobody plays',
      );
      return null;
    }
    return shares;
  }

  List<_Edge>? _edges(List<Object?> children, int depth) {
    final edges = <_Edge>[];
    for (final entry in children) {
      if (entry is! Map<String, Object?>) {
        _fail('a child of the node at depth $depth is not an object');
        return null;
      }
      final uci = entry['move_uci'];
      final san = entry['move_san'];
      if (uci is! String || san is! String) {
        _fail('a child at depth ${depth + 1} does not name its move');
        return null;
      }
      final child = read(entry, depth + 1);
      if (child == null) return null;
      final share = entry['move_probability'];
      edges.add(
        _Edge(
          move: MoveRef(uci: uci, san: san),
          // Every reader of this format has read a missing share as certainty
          // since version one.
          probability: share is num ? share.toDouble() : 1,
          child: child,
        ),
      );
    }
    return edges;
  }

  /// The format records what a finished game was worth but not why it
  /// finished. Three of the four draws are visible in the position itself; a
  /// repetition is the one that is not, so a drawn position showing no other
  /// reason is one — which is also the honest answer when the FEN cannot be
  /// read at all.
  TerminalKind _terminalReason(double value, Fen fen) {
    if (value != 0.5) return TerminalKind.checkmate;
    final position = _positionOf(fen);
    if (position == null) return TerminalKind.repetition;
    final kind = terminalKind(position, [repetitionKey(fen)]);
    return kind == null || kind == TerminalKind.checkmate
        ? TerminalKind.repetition
        : kind;
  }

  void _fail(String detail) => _refuse(TreeMalformed(detail));

  void _refuse(TreeReadResult result) => refusal ??= result;
}

final class _Edge {
  const _Edge({
    required this.move,
    required this.probability,
    required this.child,
  });

  final MoveRef move;
  final double probability;
  final SearchNode child;
}

/// The board [fen] describes, or null when it does not describe one. A file
/// written by a builder holds real positions; a hand-made or truncated one
/// need not, and that is a fact about the file rather than a crash.
Position? _positionOf(Fen fen) {
  try {
    return Chess.fromSetup(Setup.parseFen(fen.value));
  } catch (_) {
    // Any complaint from the parser means the same thing: not a position.
    return null;
  }
}
