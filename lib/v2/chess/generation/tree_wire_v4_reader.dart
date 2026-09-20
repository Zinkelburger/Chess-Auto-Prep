import 'dart:convert';

import 'package:dartchess/dartchess.dart' show Chess, Position, Setup, Side;

import '../fen.dart';
import 'eval.dart';
import 'search_config.dart';
import 'search_node.dart';
import 'terminal.dart';
import 'tree_wire_v4.dart';

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
  final unsupported = _unsupportedReason(parsed['version'], config, tree);
  if (unsupported != null) return TreeUnsupported(unsupported);
  return _readTree(tree, _configOf(config), parsed['build_complete']);
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
    return TreeMalformed(reader.failure ?? 'the tree could not be read');
  }
  return TreeDecoded(
    root: root,
    config: config,
    // A file written before builds could be interrupted carries no such key,
    // and every tree in one of those was finished.
    complete: complete is bool ? complete : true,
  );
}

/// Why this search cannot read the tree, or null when it can.
String? _unsupportedReason(
  Object? version,
  Map<String, Object?> config,
  Map<String, Object?> tree,
) {
  if (version is! num || version.toInt() != treeWireVersion) {
    return 'this tree was saved in format version ${version ?? 'unknown'}, '
        'and only version $treeWireVersion can be read';
  }
  // The flag on the root is what tells the two searches apart, and it is what
  // the old app itself checks before resuming a build; the version number
  // beside it is a label that some writers leave off.
  final algorithm = config['algorithm_version'];
  if (tree['history_aware'] != true ||
      (algorithm != null && algorithm != pureAlgorithmVersion)) {
    return 'this tree was built by the older heuristic search, which valued '
        'positions differently and shared values between paths; build it '
        'again to open it here';
  }
  final search = config['search_algorithm'];
  if (search != null && search != 'pure') {
    return 'this tree was built by the $search search, which this reader '
        'does not have';
  }
  return null;
}

/// The search the document says it was built by. Every key defaults, because
/// the C builder and the old app each leave out what their mode does not use.
SearchConfig _configOf(Map<String, Object?> config) {
  final side = config['play_as_white'] == false ? Side.black : Side.white;
  final defaults = SearchConfig(side: side);
  final budget = config['max_nodes'];
  return SearchConfig(
    side: side,
    horizonPlies: _intOr(config['max_depth'], defaults.horizonPlies),
    lossLimitCp: _intOr(config['max_eval_loss_cp'], defaults.lossLimitCp),
    nodeBudget: budget is num && budget > 0 ? budget.toInt() : null,
  );
}

int _intOr(Object? value, int fallback) =>
    value is num ? value.toInt() : fallback;

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

  String? failure;

  SearchNode? read(Map<String, Object?> json, int depth) {
    final text = json['fen'];
    if (text is! String || text.isEmpty) {
      _fail('a node at depth $depth has no FEN');
      return null;
    }
    final fen = Fen(text);
    final white = json['is_white_to_move'];
    final ourTurn =
        (white is bool ? white : fen.whiteToMove) == (ourSide == Side.white);
    final cp = json['engine_eval_cp'];
    if (cp is! num) {
      _fail('the node at ${fen.value} has no engine evaluation');
      return null;
    }
    // The file reports from the side to move; the search works from ours.
    final evalForUs = Eval(ourTurn ? cp.toInt() : -cp.toInt());
    final children = json['children'];
    if (json['terminal_value'] is num || children is! List || children.isEmpty) {
      return _leaf(json, fen, evalForUs, ourTurn: ourTurn, depth: depth);
    }
    final edges = _edges(children, depth);
    if (edges == null) return null;
    return _branch(fen, evalForUs, edges, ourTurn: ourTurn);
  }

  SearchNode _leaf(
    Map<String, Object?> json,
    Fen fen,
    Eval evalForUs, {
    required bool ourTurn,
    required int depth,
  }) {
    final terminal = json['terminal_value'];
    if (terminal is num) {
      return TerminalNode(
        fen: fen,
        evalForUs: evalForUs,
        kind: _terminalReason(terminal.toDouble(), fen),
        ourTurn: ourTurn,
      );
    }
    return depth >= horizonPlies
        ? HorizonNode(fen: fen, evalForUs: evalForUs)
        : FrontierNode(fen: fen, evalForUs: evalForUs);
  }

  SearchNode _branch(
    Fen fen,
    Eval evalForUs,
    List<_Edge> edges, {
    required bool ourTurn,
  }) => ourTurn
      ? OurNode.over(
          fen: fen,
          evalForUs: evalForUs,
          candidates: [
            for (final edge in edges)
              CandidateMove(move: edge.move, child: edge.child),
          ],
        )
      : OpponentNode.over(
          fen: fen,
          evalForUs: evalForUs,
          replies: [
            for (final edge in edges)
              ReplyMove(
                move: edge.move,
                probability: edge.probability,
                child: edge.child,
              ),
          ],
        );

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

  void _fail(String detail) => failure ??= detail;
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
