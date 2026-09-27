// The one place both tree codecs are in the same program. The old app, the C
// builder and `v2` all read and write one saved-tree file, so a tree built by
// the new search has to land where the old app reads it and an old tree has
// to come back whole. `test/v2/chess/generation/tree_wire_v4_test.dart`
// writes the format's rules out again; this runs the two implementations
// against each other. It lives outside `test/v2/` because nothing in
// `lib/v2/` may see the old app, and its mirror in `test/v2/` may not either.
import 'dart:convert';

import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/chess_core/generation/tree_serialization.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
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
const _afterC5 = 'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';

/// White queen and king against a lone black king with no move to make.
const _stalemate = '7k/5Q2/6K1/8/8/8/8/8 b - - 0 1';

// The fool's mate, 1.f3 e5 2.g4 Qh4#, and two moves off it.
const _afterF3 = 'rnbqkbnr/pppppppp/8/8/8/5P2/PPPPP1PP/RNBQKBNR b KQkq - 0 1';
const _afterA3 = 'rnbqkbnr/pppppppp/8/8/8/P7/1PPPPPPP/RNBQKBNR b KQkq - 0 1';
const _afterF3E5 =
    'rnbqkbnr/pppp1ppp/8/4p3/8/5P2/PPPPP1PP/RNBQKBNR w KQkq - 0 2';
const _afterF3A5 =
    'rnbqkbnr/1ppppppp/8/p7/8/5P2/PPPPP1PP/RNBQKBNR w KQkq - 0 2';
const _afterG4 =
    'rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2';
const _afterNc3 =
    'rnbqkbnr/pppp1ppp/8/4p3/8/2N2P2/PPPPP1PP/R1BQKB1R b KQkq - 1 2';
const _afterQh4 =
    'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3';
const _afterD6 =
    'rnbqkbnr/ppp2ppp/3p4/4p3/6P1/5P2/PPPPP2P/RNBQKBNR w KQkq - 0 3';

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

/// The same build stopped one step earlier, the way the old builder leaves a
/// paused, cancelled or budget-stopped tree: it attaches a position's whole
/// set of replies first and evaluates them afterwards, so the replies are in
/// the file with no engine evaluation of their own.
BuildTree _pausedOldAppTree() {
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
  );
  final c5 = _oldNode(
    _afterC5,
    ply: 2,
    isWhiteToMove: true,
    nodeId: 4,
    uci: 'c7c5',
    san: 'c5',
    probability: 0.25,
  );
  root.children.add(e4);
  e4.children.addAll([e5, c5]);
  return BuildTree(
    root: root,
    totalNodes: 4,
    maxPlyReached: 2,
    buildComplete: false,
    configSnapshot: const {
      'algorithm_version': 3,
      'search_algorithm': 'pure',
      'opponent_book_source': 'none',
      'play_as_white': true,
      'max_depth': 4,
      'max_eval_loss_cp': 200,
    },
  );
}

/// Every kind of node one file can hold, for White, with the build stopped
/// before it was finished: our nodes and the opponent's, a mate and a draw,
/// an evaluated leaf at the horizon, an evaluated frontier short of it and
/// one the build never evaluated at all.
///
/// The line 1.f3 e5 2.g4 Qh4# runs down the middle of it. The two positions
/// that only have to be a draw and an unrelated frontier are written in
/// directly: neither codec replays a move, so what each node *is* is the
/// whole of what this fixture says.
BuildTree _mixedOldAppTree() {
  final root = _oldNode(_start, ply: 0, isWhiteToMove: true, nodeId: 1)
    ..engineEvalCp = 25
    ..explored = true;
  final f3 =
      _oldNode(
          _afterF3,
          ply: 1,
          isWhiteToMove: false,
          nodeId: 2,
          uci: 'f2f3',
          san: 'f3',
        )
        ..engineEvalCp = -25
        ..explored = true
        ..isRepertoireMove = true;
  final a3 = _oldNode(
    _afterA3,
    ply: 1,
    isWhiteToMove: false,
    nodeId: 3,
    uci: 'a2a3',
    san: 'a3',
  )..engineEvalCp = -20;
  final e5 =
      _oldNode(
          _afterF3E5,
          ply: 2,
          isWhiteToMove: true,
          nodeId: 4,
          uci: 'e7e5',
          san: 'e5',
          probability: 0.75,
        )
        ..engineEvalCp = 10
        ..explored = true;
  final a5 = _oldNode(
    _afterF3A5,
    ply: 2,
    isWhiteToMove: true,
    nodeId: 5,
    uci: 'a7a5',
    san: 'a5',
    probability: 0.25,
  );
  final g4 =
      _oldNode(
          _afterG4,
          ply: 3,
          isWhiteToMove: false,
          nodeId: 6,
          uci: 'g2g4',
          san: 'g4',
        )
        ..engineEvalCp = -40
        ..explored = true
        ..isRepertoireMove = true;
  final nc3 = _oldNode(
    _afterNc3,
    ply: 3,
    isWhiteToMove: false,
    nodeId: 7,
    uci: 'b1c3',
    san: 'Nc3',
  )..engineEvalCp = -5;
  final drawn =
      _oldNode(
          _stalemate,
          ply: 3,
          isWhiteToMove: false,
          nodeId: 8,
          uci: 'd1e2',
          san: 'Qe2',
        )
        ..engineEvalCp = 0
        ..terminalValue = 0.5;
  final mate =
      _oldNode(
          _afterQh4,
          ply: 4,
          isWhiteToMove: true,
          nodeId: 9,
          uci: 'd8h4',
          san: 'Qh4#',
          probability: 0.5,
        )
        ..engineEvalCp = -9999
        ..terminalValue = 0;
  final d6 = _oldNode(
    _afterD6,
    ply: 4,
    isWhiteToMove: true,
    nodeId: 10,
    uci: 'd7d6',
    san: 'd6',
    probability: 0.5,
  )..engineEvalCp = 50;
  root.children.addAll([f3, a3]);
  f3.children.addAll([e5, a5]);
  e5.children.addAll([g4, nc3, drawn]);
  g4.children.addAll([mate, d6]);
  return BuildTree(
    root: root,
    totalNodes: 10,
    maxPlyReached: 4,
    buildComplete: false,
    configSnapshot: const {
      'algorithm_version': 3,
      'search_algorithm': 'pure',
      'opponent_book_source': 'none',
      'play_as_white': true,
      'max_depth': 4,
      'max_eval_loss_cp': 200,
    },
  );
}

/// The settings [_mixedOldAppTree] records, so the old backup runs under the
/// model that built it rather than re-scoring the tree under another one.
const _mixedConfig = TreeBuildConfig(
  startFen: _start,
  playAsWhite: true,
  maxPly: 4,
  maxEvalLossCp: 200,
);

/// Fails unless the two implementations put the same number on every node.
///
/// The old app stores what its backup worked out; the new one recomputes it
/// from the shape of the tree. Agreeing on one tree node by node is the only
/// evidence that neither is quietly valuing a different search.
void _expectSameValues(
  SearchNode node,
  BuildTreeNode old, {
  String where = 'the root',
}) {
  expect(node.fen.value, old.fen, reason: where);
  expect(
    node.valuation.value,
    closeTo(old.expectimaxValue, 1e-9),
    reason: where,
  );
  expect(node.valuation.lower, closeTo(old.valueLower, 1e-9), reason: where);
  expect(node.valuation.upper, closeTo(old.valueUpper, 1e-9), reason: where);
  final branches = {for (final branch in branchesOf(node)) branch.uci: branch};
  expect(
    branches.keys,
    unorderedEquals(old.children.map((child) => child.moveUci)),
    reason: where,
  );
  for (final child in old.children) {
    _expectSameValues(
      branches[child.moveUci]!.child,
      child,
      where: '$where → ${child.moveSan}',
    );
  }
}

BuildTreeNode _childByUci(BuildTreeNode node, String uci) =>
    node.children.firstWhere((child) => child.moveUci == uci);

/// The root node of a written document, as the JSON it is.
Map<String, Object?> _writtenRoot(String document) =>
    (jsonDecode(document) as Map<String, Object?>)['tree']!
        as Map<String, Object?>;

List<Map<String, Object?>> _writtenChildren(Map<String, Object?> node) =>
    (node['children']! as List).cast<Map<String, Object?>>();

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

  test('the old app gets the line and the settings it resumes from', () async {
    final tree = await _newSearchTree();

    final old = deserializeTree(
      encodeTreeV4(
        tree,
        _config,
        complete: false,
        startMoves: const ['e4', 'c5'],
        evalDepth: 18,
        opponentRating: 1900,
      ),
    );

    // Without these three a resume either refuses or exports its lines from
    // the wrong place: the prefix is how the old app knows where the root is.
    expect(old.startMoves, 'e4 c5');
    expect(old.configSnapshot['eval_depth'], 18);
    expect(old.configSnapshot['maia_elo'], 1900);
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
    expect(
      opponent.replies.single.probability,
      1,
      reason: 'the only reply saved holds the whole of what this node does',
    );

    final horizon = opponent.replies.single.child;
    expect(horizon, isA<HorizonNode>());
    expect(horizon.evalForUs.cp, 30);
    expect(horizon.valuation.isExact, isTrue);
  });

  test('a build the old app paused mid-expansion comes back whole', () {
    final result = decodeTreeV4(serializeTree(_pausedOldAppTree()));

    expect(result, isA<TreeDecoded>());
    final decoded = result as TreeDecoded;
    expect(decoded.complete, isFalse);

    final opponent = (decoded.root as OurNode).chosen.child as OpponentNode;
    expect(opponent.replies.length, 2);
    for (final reply in opponent.replies) {
      expect(
        reply.child,
        isA<FrontierNode>(),
        reason: 'attached, not yet evaluated',
      );
      expect(reply.child.evalForUs.cp, 0);
      expect(reply.child.valuation.isExact, isFalse);
    }
    expect(decoded.root.valuation.isExact, isFalse);
  });

  test('a paused build goes back unevaluated, not evaluated at zero', () {
    final decoded =
        decodeTreeV4(serializeTree(_pausedOldAppTree())) as TreeDecoded;

    final written = encodeTreeV4(decoded.root, decoded.config, complete: false);
    final again = deserializeTree(written);

    final replies = _childByUci(again.root, 'e2e4').children;
    expect(replies.map((reply) => reply.moveUci), ['e7e5', 'c7c5']);
    for (final reply in replies) {
      // A zero here is an engine's verdict of level, and the old builder
      // never looks at such a node again: the resume would trust a score
      // nothing produced.
      expect(reply.hasEngineEval, isFalse, reason: reply.moveSan);
    }
    expect(again.root.engineEvalCp, 25, reason: 'the scored nodes keep theirs');
    expect(_childByUci(again.root, 'e2e4').engineEvalCp, -25);
    final e4 = _writtenChildren(_writtenRoot(written)).single;
    for (final reply in _writtenChildren(e4)) {
      expect(reply.containsKey('engine_eval_cp'), isFalse);
    }
  });

  test('a branch the old app never scored is written unscored too', () {
    // A node with moves under it and no evaluation of its own: the scores
    // and the shape of a tree are recorded separately, so one can be
    // missing while the other is whole.
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
          ..explored = true
          ..isRepertoireMove = true;
    final e5 = _oldNode(
      _afterE5,
      ply: 2,
      isWhiteToMove: true,
      nodeId: 3,
      uci: 'e7e5',
      san: 'e5',
    )..engineEvalCp = 30;
    root.children.add(e4);
    e4.children.add(e5);
    final decoded =
        decodeTreeV4(
              serializeTree(
                BuildTree(
                  root: root,
                  totalNodes: 3,
                  maxPlyReached: 2,
                  buildComplete: false,
                  configSnapshot: const {
                    'algorithm_version': 3,
                    'search_algorithm': 'pure',
                    'play_as_white': true,
                    'max_depth': 2,
                    'max_eval_loss_cp': 200,
                  },
                ),
              ),
            )
            as TreeDecoded;

    final written = encodeTreeV4(decoded.root, decoded.config, complete: false);
    final again = deserializeTree(written);

    final branch = _childByUci(again.root, 'e2e4');
    expect(branch.hasEngineEval, isFalse, reason: 'it never had one');
    expect(_childByUci(branch, 'e7e5').engineEvalCp, 30);
    expect(
      _writtenChildren(
        _writtenRoot(written),
      ).single.containsKey('engine_eval_cp'),
      isFalse,
    );
  });

  test('both searches put the same value on every node of one tree', () {
    final old = _mixedOldAppTree();
    ExpectimaxCalculator(config: _mixedConfig).calculate(old);

    final decoded = decodeTreeV4(serializeTree(old)) as TreeDecoded;

    expect(decoded.complete, isFalse);
    _expectSameValues(decoded.root, old.root);
    // The tree is only worth reading node by node if it has every kind of
    // node in it, so the fixture is checked as well as the values.
    final ours = decoded.root as OurNode;
    final f3 = ours.candidates.firstWhere((c) => c.move.uci == 'f2f3').child;
    final e5 = (f3 as OpponentNode).replies
        .firstWhere((r) => r.move.uci == 'e7e5')
        .child;
    final g4 = (e5 as OurNode).candidates
        .firstWhere((c) => c.move.uci == 'g2g4')
        .child;
    expect(
      (f3.replies.firstWhere((r) => r.move.uci == 'a7a5').child),
      isA<FrontierNode>(),
      reason: 'attached, never evaluated',
    );
    expect(
      e5.candidates.firstWhere((c) => c.move.uci == 'b1c3').child,
      isA<FrontierNode>(),
      reason: 'evaluated, short of the horizon',
    );
    expect(
      e5.candidates.firstWhere((c) => c.move.uci == 'd1e2').child,
      isA<TerminalNode>(),
    );
    final replies = (g4 as OpponentNode).replies;
    expect(
      replies.firstWhere((r) => r.move.uci == 'd8h4').child,
      isA<TerminalNode>(),
    );
    expect(
      replies.firstWhere((r) => r.move.uci == 'd7d6').child,
      isA<HorizonNode>(),
    );
  });

  test('a draw the old app saved comes back a draw, with its reason', () {
    final drawn = _oldNode(_stalemate, ply: 0, isWhiteToMove: false, nodeId: 1)
      ..engineEvalCp = 0
      ..terminalValue = 0.5;
    final tree = BuildTree(
      root: drawn,
      buildComplete: true,
      configSnapshot: const {
        'algorithm_version': 3,
        'play_as_white': true,
        'max_depth': 2,
      },
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
