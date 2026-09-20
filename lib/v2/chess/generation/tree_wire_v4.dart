import 'dart:convert';

import 'package:dartchess/dartchess.dart' show Side;

import 'search_config.dart';
import 'search_node.dart';

/// Writes the v4 saved-tree format: the one file the old app and the
/// standalone C builder both read, so a tree built here can be opened there.
/// [decodeTreeV4] in `tree_wire_v4_reader.dart` reads it back.
///
/// A document is one JSON object: `format`, `version`, `total_nodes`,
/// `max_depth`, `build_complete`, a flat snake_case `config` snapshot and the
/// root `tree` node, each node carrying its own `children`. A node names the
/// move that reached it twice, as `move_uci` and `move_san`, and carries its
/// `fen`, its `engine_eval_cp` **from the side to move** the way UCI reports
/// one — left out entirely by a node no engine has scored, which is how every
/// reader of this format tells the unscored from the level —, its
/// `move_probability` and `cumulative_probability`, its
/// `value_lower` and `value_upper`, and `terminal_value` when the game ended
/// there. Everything else a node may carry belongs to a mode this search does
/// not have — master-game counts, book sources, trap and ease scores, prune
/// reasons, rolling-search commitments, transposition rings — and is read
/// past, never written.
///
/// What the format does not record is *why* a finished game finished: only
/// what it was worth. The reader works the reason back out of the position.
///
/// Values here are the search's own: an expected score in [0, 1] for the
/// repertoire side. Probabilities are written with Dart's shortest
/// round-tripping decimal, so a share that comes back is the double that went
/// out; the C builder prints 17 significant digits for the same reason.
const String treeWireFormat = 'opening_tree';

/// The format version this codec reads and writes.
const int treeWireVersion = 4;

/// What the configuration snapshot calls history-aware pure expectimax: the
/// search in `search.dart`. Version 1 was the heuristic search, which valued
/// positions differently and shared values between paths.
const int pureAlgorithmVersion = 3;

/// [root] and [config] as a v4 document, with [complete] saying whether the
/// search reached the horizon everywhere.
///
/// [startMoves] is the line in SAN from the initial position down to [root],
/// and is left out when the root is the initial position. The old app plays
/// it back to place its board before it continues a saved build, and without
/// it a build can only be resumed from a board that already stands on the
/// root.
///
/// [evalDepth] and [opponentRating] are the engine depth and the Maia rating
/// this tree was built with. The search itself is handed an evaluator and a
/// policy rather than the numbers behind them, so whoever owns those numbers
/// passes them here. A tree written without them stays readable everywhere —
/// they are settings, not values — but the old app cannot resume it: its
/// resume check requires the saved settings to equal the current ones, and an
/// absent setting never does.
String encodeTreeV4(
  SearchNode root,
  SearchConfig config, {
  required bool complete,
  List<String> startMoves = const [],
  int? evalDepth,
  int? opponentRating,
}) {
  final writer = _Writer(ourSide: config.side);
  final tree = writer.write(
    root,
    move: null,
    depth: 0,
    probability: 1,
    cumulative: 1,
  );
  return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
    'format': treeWireFormat,
    'version': treeWireVersion,
    'total_nodes': writer.nodes,
    'max_depth': writer.deepest,
    'build_complete': complete,
    if (startMoves.isNotEmpty) 'start_moves': startMoves.join(' '),
    'config': _configJson(config, evalDepth, opponentRating),
    'tree': tree,
  });
}

/// The flat snapshot the old app restores a build's settings from.
///
/// The constants are what this search is: pure expectimax against a Maia
/// policy alone, with no opening book and no master games behind the
/// opponent's replies. The old app's own snapshot has some seventy further
/// keys, for modes this search does not have; every one of them defaults when
/// it is absent, so they are left out rather than invented. The two the
/// caller may know, [evalDepth] and [opponentRating], are written when it
/// does and left out when it does not.
Map<String, Object?> _configJson(
  SearchConfig config,
  int? evalDepth,
  int? opponentRating,
) => <String, Object?>{
  'algorithm_version': pureAlgorithmVersion,
  'search_algorithm': 'pure',
  'build_mode': 'stockfishExpectimax',
  'opponent_book_source': 'none',
  'use_master_games': false,
  'maia_only': true,
  'maia_policy_version': 1,
  'play_as_white': config.side == Side.white,
  'max_depth': config.horizonPlies,
  'max_eval_loss_cp': config.lossLimitCp,
  'max_nodes': ?config.nodeBudget,
  'eval_depth': ?evalDepth,
  'maia_elo': ?opponentRating,
};

/// Walks the tree once, numbering the nodes and counting them as it goes.
final class _Writer {
  _Writer({required this.ourSide});

  final Side ourSide;

  /// How many nodes have been written; the next id is one more than this.
  int nodes = 0;

  /// The deepest ply reached, for the document's `max_depth`.
  int deepest = 0;

  Map<String, Object?> write(
    SearchNode node, {
    required MoveRef? move,
    required int depth,
    required double probability,
    required double cumulative,
  }) {
    nodes += 1;
    if (depth > deepest) deepest = depth;
    final valuation = node.valuation;
    final json = <String, Object?>{
      'id': nodes,
      'depth': depth,
      if (move != null) 'move_san': move.san,
      if (move != null) 'move_uci': move.uci,
      'history_aware': true,
      'fen': node.fen.value,
      'is_white_to_move': node.fen.whiteToMove,
      'engine_eval_cp': ?_sideToMoveCp(node),
      'move_probability': probability,
      'cumulative_probability': cumulative,
      if (node is TerminalNode) 'terminal_value': valuation.value,
      'value_lower': valuation.lower,
      'value_upper': valuation.upper,
      // The old app shows a node's value from these two and reads them as a
      // pair. This search measures no centipawn loss, so the display-only
      // half of the pair is written as the zero it is.
      'local_cpl': 0.0,
      'expectimax_value': valuation.value,
    };
    final children = _children(node, depth, cumulative);
    if (children.isNotEmpty) {
      json['explored'] = true;
      json['children'] = children;
    }
    return json;
  }

  List<Map<String, Object?>> _children(
    SearchNode node,
    int depth,
    double cumulative,
  ) => switch (node) {
    OurNode(:final candidates) => _ourMoves(candidates, depth, cumulative),
    OpponentNode(:final replies) => [
      for (final reply in replies)
        write(
          reply.child,
          move: reply.move,
          depth: depth + 1,
          probability: reply.probability,
          cumulative: cumulative * reply.probability,
        ),
    ],
    TerminalNode() || HorizonNode() || FrontierNode() => const [],
  };

  /// Our moves all have probability one — we choose — and the probability of
  /// reaching a position only falls on the opponent's moves.
  List<Map<String, Object?>> _ourMoves(
    List<CandidateMove> candidates,
    int depth,
    double cumulative,
  ) {
    final children = [
      for (final candidate in candidates)
        write(
          candidate.child,
          move: candidate.move,
          depth: depth + 1,
          probability: 1,
          cumulative: cumulative,
        ),
    ];
    // Candidates are in the order the node would play them, so the first is
    // the move the repertoire takes, which is what the flag means.
    children.first['is_repertoire_move'] = true;
    return children;
  }

  /// The file reports an evaluation the way UCI does, from the side to move,
  /// while the search holds it from the repertoire side, so one negation
  /// converts it whenever the opponent is the one on move.
  ///
  /// A node nobody has evaluated has none to report, and none is written: a
  /// zero here is a score, and every builder that reads this file takes a
  /// scored node as one it need never look at again — so a resumed build
  /// would carry on from an evaluation no engine ever gave.
  int? _sideToMoveCp(SearchNode node) {
    if (!node.evaluated) return null;
    return node.fen.whiteToMove == (ourSide == Side.white)
        ? node.evalForUs.cp
        : -node.evalForUs.cp;
  }
}
