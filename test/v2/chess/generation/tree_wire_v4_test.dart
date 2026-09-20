import 'dart:convert';

import 'package:chess_auto_prep/v2/chess/generation/search.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_config.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_result.dart';
import 'package:chess_auto_prep/v2/chess/generation/sources.dart';
import 'package:chess_auto_prep/v2/chess/generation/tree_wire_v4.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import 'scripted_sources.dart';
import 'tree_sameness.dart';
import 'wire_documents.dart';

/// White king and pawn against a bare black king: six legal moves for White
/// and a handful for Black, so a three-ply tree is small enough to read.
const _kingAndPawn = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';

/// The same position at the hundredth quiet half-move, so every king move
/// below it ends the game and every pawn move does not.
const _almostFifty = '4k3/8/8/8/8/8/4P3/4K3 w - - 99 60';

const _foolsMate =
    'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3';

/// Two replies with shares that are not round numbers in binary, so the file
/// has to carry the doubles themselves rather than something close to them.
const _twoReplies = ScriptedPolicy({'e8d8': 2, 'e8f8': 1});

Future<SearchNode> _treeFrom(
  String fen, {
  required SearchConfig config,
  OpponentPolicy policy = _twoReplies,
}) async {
  final result = await buildSearchTree(
    root: positionOf(fen),
    config: config,
    evaluator: ScriptedEvaluator(scores: {positionOf(fen).fen: 40}),
    policy: policy,
  );
  return switch (result) {
    SearchComplete(:final tree) => tree,
    SearchIncomplete(:final tree) => tree,
    _ => fail('expected a tree, got $result'),
  };
}

Map<String, Object?> _asJson(String text) =>
    jsonDecode(text) as Map<String, Object?>;

void main() {
  test('a finished tree comes back the tree that went out', () async {
    const config = SearchConfig(side: Side.white, horizonPlies: 3);
    final tree = await _treeFrom(_kingAndPawn, config: config);

    final decoded = decodedTree(encodeTreeV4(tree, config, complete: true));

    expectSameTree(decoded.root, tree);
    expect(decoded.complete, isTrue);
    expect(decoded.config.side, Side.white);
    expect(decoded.config.horizonPlies, 3);
    expect(decoded.config.lossLimitCp, config.lossLimitCp);
    expect(decoded.config.nodeBudget, isNull);
  });

  test('a tree for Black comes back a tree for Black', () async {
    const config = SearchConfig(side: Side.black, horizonPlies: 2);
    final tree = await _treeFrom(
      _kingAndPawn,
      config: config,
      policy: const ScriptedPolicy({'e2e4': 3, 'e1e2': 1}),
    );

    final decoded = decodedTree(encodeTreeV4(tree, config, complete: true));

    expect(decoded.config.side, Side.black);
    expectSameTree(decoded.root, tree);
  });

  test('an unfinished tree keeps its unexpanded leaves', () async {
    const config = SearchConfig(
      side: Side.white,
      horizonPlies: 4,
      nodeBudget: 8,
    );
    final tree = await _treeFrom(_kingAndPawn, config: config);

    final decoded = decodedTree(encodeTreeV4(tree, config, complete: false));

    expectSameTree(decoded.root, tree);
    expect(decoded.complete, isFalse);
    expect(decoded.config.nodeBudget, 8);
    expect(decoded.root.valuation.isExact, isFalse);
  });

  test('a finished game keeps what it was worth and why it ended', () async {
    const config = SearchConfig(side: Side.white, horizonPlies: 2);
    final tree = await _treeFrom(_almostFifty, config: config);

    final decoded = decodedTree(encodeTreeV4(tree, config, complete: true));

    final drawn = (decoded.root as OurNode).candidates
        .map((candidate) => candidate.child)
        .whereType<TerminalNode>();
    expect(drawn, isNotEmpty, reason: 'a king move here draws by the rule');
    expect(
      drawn.map((node) => node.kind),
      everyElement(TerminalKind.fiftyMoveRule),
    );
    expectSameTree(decoded.root, tree);
  });

  test('a checkmate at the root survives on its own', () async {
    const config = SearchConfig(side: Side.white, horizonPlies: 2);
    final tree = await _treeFrom(_foolsMate, config: config);

    final decoded = decodedTree(encodeTreeV4(tree, config, complete: true));

    expect((decoded.root as TerminalNode).kind, TerminalKind.checkmate);
    expect(decoded.root.valuation.value, 0);
    expectSameTree(decoded.root, tree);
  });

  test('the shares the opponent model gave are the shares read back', () async {
    const config = SearchConfig(side: Side.white, horizonPlies: 2);
    final tree = await _treeFrom(_kingAndPawn, config: config);

    final decoded = decodedTree(encodeTreeV4(tree, config, complete: true));

    final replies =
        ((decoded.root as OurNode).chosen.child as OpponentNode).replies;
    expect(
      replies.map((reply) => reply.probability),
      unorderedEquals(<double>[2 / 3, 1 / 3]),
      reason: 'exactly, not nearly: the file carries the doubles themselves',
    );
  });

  test('the document says which model built it', () async {
    const config = SearchConfig(side: Side.black, horizonPlies: 2);
    final tree = await _treeFrom(
      _kingAndPawn,
      config: config,
      policy: const ScriptedPolicy({'e2e4': 3, 'e1e2': 1}),
    );

    final document = _asJson(encodeTreeV4(tree, config, complete: true));

    expect(document['format'], 'opening_tree');
    expect(document['version'], 4);
    expect(document['build_complete'], isTrue);
    expect((document['tree']! as Map<String, Object?>)['history_aware'], true);
    expect(document['config'], <String, Object?>{
      'algorithm_version': 3,
      'search_algorithm': 'pure',
      'build_mode': 'stockfishExpectimax',
      'opponent_book_source': 'none',
      'use_master_games': false,
      'maia_only': true,
      'maia_policy_version': 1,
      'play_as_white': false,
      'max_depth': 2,
      'max_eval_loss_cp': 200,
    });
  });

  test('a node the build never evaluated is written without a score', () {
    // A paused build, the way one is left behind: the reply is attached and
    // the engine has not looked at it yet.
    final decoded = decodedTree(
      wireDocument(
        tree: <String, Object?>{
          ...oneNode,
          'children': [
            <String, Object?>{
              'id': 2,
              'depth': 1,
              'move_uci': 'e2e4',
              'move_san': 'e4',
              'history_aware': true,
              'fen': afterE4,
              'is_white_to_move': false,
            },
          ],
        },
      ),
    );

    final root =
        _asJson(
              encodeTreeV4(decoded.root, decoded.config, complete: false),
            )['tree']!
            as Map<String, Object?>;
    final reply = (root['children']! as List).single as Map<String, Object?>;

    expect(root['engine_eval_cp'], 20, reason: 'the scored node keeps its own');
    expect(
      reply.containsKey('engine_eval_cp'),
      isFalse,
      reason: 'a written zero is a score no engine gave',
    );
  });

  test('a document without the resume settings leaves them out', () async {
    const config = SearchConfig(side: Side.white, horizonPlies: 2);
    final tree = await _treeFrom(_kingAndPawn, config: config);

    final document = _asJson(encodeTreeV4(tree, config, complete: true));
    final saved = document['config']! as Map<String, Object?>;

    expect(document.containsKey('start_moves'), isFalse);
    expect(saved.containsKey('eval_depth'), isFalse);
    expect(saved.containsKey('maia_elo'), isFalse);
  });

  test(
    'the settings the old app resumes from are written when known',
    () async {
      const config = SearchConfig(side: Side.white, horizonPlies: 2);
      final tree = await _treeFrom(_kingAndPawn, config: config);

      final document = _asJson(
        encodeTreeV4(
          tree,
          config,
          complete: false,
          startMoves: const ['e4', 'c5'],
          evalDepth: 18,
          opponentRating: 1900,
        ),
      );
      final saved = document['config']! as Map<String, Object?>;

      expect(document['start_moves'], 'e4 c5');
      expect(saved['eval_depth'], 18);
      expect(saved['maia_elo'], 1900);
    },
  );
}
