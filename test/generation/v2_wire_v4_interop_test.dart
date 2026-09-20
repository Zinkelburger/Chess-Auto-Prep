// The one place both tree codecs are in the same program. The old app, the C
// builder and `v2` all read and write one saved-tree file, so a tree built by
// the new search has to land where the old app reads it and an old tree has
// to come back whole. `test/v2/chess/generation/tree_wire_v4_test.dart`
// writes the format's rules out again; this runs the two implementations
// against each other. It lives outside `test/v2/` because nothing in
// `lib/v2/` may see the old app, and its mirror in `test/v2/` may not either.
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/chess_core/generation/tree_serialization.dart';
import 'package:chess_auto_prep/v2/chess/generation/search.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_config.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_result.dart';
import 'package:chess_auto_prep/v2/chess/generation/tree_wire_v4.dart';
import 'package:chess_auto_prep/v2/chess/generation/tree_wire_v4_reader.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../v2/chess/generation/scripted_sources.dart';
import '../v2/chess/generation/tree_sameness.dart';

const _kingAndPawn = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';
const _start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
const _afterE5 = 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';

/// White queen and king against a lone black king with no move to make.
const _stalemate = '7k/5Q2/6K1/8/8/8/8/8 b - - 0 1';

const _config = SearchConfig(side: Side.white, horizonPlies: 2);

Future<SearchNode> _newSearchTree() async {
  final result = await buildSearchTree(
    root: positionOf(_kingAndPawn),
    config: _config,
    evaluator: ScriptedEvaluator(scores: {_kingAndPawn: 60}),
    policy: const ScriptedPolicy({'e8d8': 2, 'e8f8': 1}),
  );
  return switch (result) {
    SearchComplete(:final tree) => tree,
    _ => fail('expected a finished tree, got $result'),
  };
}

BuildTreeNode _oldNode(
  String fen, {
  required int ply,
  required bool isWhiteToMove,
  required int nodeId,
  String uci = '',
  String san = '',
  double probability = 1,
}) => BuildTreeNode(
  fen: fen,
  moveSan: san,
  moveUci: uci,
  ply: ply,
  isWhiteToMove: isWhiteToMove,
  nodeId: nodeId,
  moveProbability: probability,
  cumulativeProbability: probability,
)..historyAware = true;

/// A three-node tree with the old app's own types, the way its builder leaves
/// one: 1.e4 played by us, one reply the opponent model gave three quarters
/// of its weight, and the horizon under it.
BuildTree _oldAppTree() {
  final root = _oldNode(_start, ply: 0, isWhiteToMove: true, nodeId: 1)
    ..engineEvalCp = 25
    ..explored = true;
  final e4 =
      _oldNode(
          _afterE4,
          ply: 1,
          isWhiteToMove: false,
          nodeId: 2,
          uci: 'e2e4',
          san: 'e4',
        )
        ..engineEvalCp = -25
        ..explored = true
        ..isRepertoireMove = true;
  final e5 = _oldNode(
    _afterE5,
    ply: 2,
    isWhiteToMove: true,
    nodeId: 3,
    uci: 'e7e5',
    san: 'e5',
    probability: 0.75,
  )..engineEvalCp = 30;
  root.children.add(e4);
  e4.children.add(e5);
  return BuildTree(
    root: root,
    totalNodes: 3,
    maxPlyReached: 2,
    buildComplete: true,
    configSnapshot: const {
      'algorithm_version': 3,
      'search_algorithm': 'pure',
      'opponent_book_source': 'none',
      'play_as_white': true,
      'max_depth': 2,
      'max_eval_loss_cp': 200,
    },
  );
}

BuildTreeNode _childByUci(BuildTreeNode node, String uci) =>
    node.children.firstWhere((child) => child.moveUci == uci);

void main() {
  test('the old app reads a tree the new search built', () async {
    final tree = await _newSearchTree();

    final old = deserializeTree(encodeTreeV4(tree, _config, complete: true));

    expect(old.buildComplete, isTrue);
    expect(old.root.historyAware, isTrue, reason: 'or it refuses to resume');
    expect(old.root.fen, _kingAndPawn);
    expect(old.root.explored, isTrue);
    expect(old.totalNodes, greaterThan(1));
    expect(old.configSnapshot['algorithm_version'], 3);
    expect(old.configSnapshot['search_algorithm'], 'pure');
    expect(old.configSnapshot['opponent_book_source'], 'none');
    expect(old.configSnapshot['use_master_games'], isFalse);
    expect(old.configSnapshot['maia_only'], isTrue);
    expect(old.configSnapshot['maia_policy_version'], 1);
    expect(old.configSnapshot['play_as_white'], isTrue);
    expect(old.configSnapshot['max_depth'], 2);
    expect(old.configSnapshot['max_eval_loss_cp'], 200);
  });

  test('the old app reads the same numbers off every node', () async {
    final tree = await _newSearchTree();
    final chosen = (tree as OurNode).chosen;
    final replies = (chosen.child as OpponentNode).replies;

    final old = deserializeTree(encodeTreeV4(tree, _config, complete: true));

    expect(old.root.engineEvalCp, 60, reason: 'reported from the side to move');
    expect(old.root.expectimaxValue, closeTo(tree.valuation.value, 1e-12));
    expect(old.root.valueLower, closeTo(tree.valuation.lower, 1e-12));
    expect(old.root.valueUpper, closeTo(tree.valuation.upper, 1e-12));
    // Sorting puts the move we play first, which is how the old app reads a
    // repertoire back out of a tree.
    expect(old.root.children.first.moveUci, chosen.move.uci);
    expect(old.root.children.first.isRepertoireMove, isTrue);
    final theirs = _childByUci(old.root, chosen.move.uci);
    expect(theirs.moveSan, chosen.move.san);
    expect(theirs.explored, isTrue);
    for (final reply in replies) {
      final node = _childByUci(theirs, reply.move.uci);
      expect(node.moveProbability, reply.probability);
      expect(node.fen, reply.child.fen.value);
      expect(node.explored, isFalse, reason: 'the horizon is not expanded');
    }
  });

  test('a tree through the old app comes back the tree it was', () async {
    final tree = await _newSearchTree();

    final old = deserializeTree(encodeTreeV4(tree, _config, complete: true));
    final result = decodeTreeV4(serializeTree(old));

    expect(result, isA<TreeDecoded>());
    final decoded = result as TreeDecoded;
    expect(decoded.complete, isTrue);
    expect(decoded.config.side, Side.white);
    expect(decoded.config.horizonPlies, 2);
    expect(decoded.config.lossLimitCp, 200);
    expectSameTree(decoded.root, tree);
  });

  test('the new search reads a tree the old app wrote', () {
    final result = decodeTreeV4(serializeTree(_oldAppTree()));

    expect(result, isA<TreeDecoded>());
    final decoded = result as TreeDecoded;
    expect(decoded.config.side, Side.white);
    expect(decoded.config.horizonPlies, 2);

    final root = decoded.root as OurNode;
    expect(root.fen.value, _start);
    expect(root.evalForUs.cp, 25);
    expect(root.chosen.move.uci, 'e2e4');
    expect(root.chosen.move.san, 'e4');

    final opponent = root.chosen.child as OpponentNode;
    expect(opponent.fen.value, _afterE4);
    expect(opponent.evalForUs.cp, 25, reason: 'their −25 is our +25');
    expect(opponent.replies.single.probability, 0.75);

    final horizon = opponent.replies.single.child;
    expect(horizon, isA<HorizonNode>());
    expect(horizon.evalForUs.cp, 30);
    expect(horizon.valuation.isExact, isTrue);
  });

  test('a draw the old app saved comes back a draw, with its reason', () {
    final drawn = _oldNode(_stalemate, ply: 0, isWhiteToMove: false, nodeId: 1)
      ..engineEvalCp = 0
      ..terminalValue = 0.5;
    final tree = BuildTree(
      root: drawn,
      buildComplete: true,
      configSnapshot: const {'algorithm_version': 3, 'play_as_white': true},
    );

    final decoded = decodeTreeV4(serializeTree(tree)) as TreeDecoded;

    final terminal = decoded.root as TerminalNode;
    expect(terminal.valuation.value, 0.5);
    expect(terminal.ourTurn, isFalse);
    // The file records what the game was worth, never why it ended; the
    // position is where the reason comes from.
    expect(terminal.kind, TerminalKind.stalemate);
  });
}
