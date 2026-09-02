/// `replyWindowCp`: prefer the candidate that leaves the opponent the
/// fewest good replies, read from the tree, inside the eval-loss guard.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/node_selection.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generation_test_helpers.dart';

const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
const _afterD4 = 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1';

const _base = TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  relativeEval: false,
  selectionMode: SelectionMode.expectimax,
  maxEvalLossCp: 50,
);

/// Root with two level candidates. Evals are side-to-move relative, so a
/// Black-to-move child at -30 is +30 for White.
///
///   e4 (+30 for us, V 0.60): Black replies e5 (level), c5 (level), a6 (-80)
///   d4 (+29 for us, V 0.55): Black replies d5 (level), h5 (-90)
({BuildTreeNode root, BuildTreeNode e4, BuildTreeNode d4}) _tree() {
  resetNodeIds();
  final root = makeNode(
    fen: kStandardStartFen,
    san: '',
    ply: 0,
    isWhiteToMove: true,
  );
  final e4 = makeNode(
    fen: _afterE4,
    san: 'e4',
    uci: 'e2e4',
    ply: 1,
    isWhiteToMove: false,
    evalCp: -30,
    parent: root,
  );
  final d4 = makeNode(
    fen: _afterD4,
    san: 'd4',
    uci: 'd2d4',
    ply: 1,
    isWhiteToMove: false,
    evalCp: -29,
    parent: root,
  );
  e4
    ..expectimaxValue = 0.60
    ..hasExpectimax = true;
  d4
    ..expectimaxValue = 0.55
    ..hasExpectimax = true;

  void reply(BuildTreeNode parent, String san, String fen, int cpWhite) {
    makeNode(
      fen: fen,
      san: san,
      ply: 2,
      isWhiteToMove: true,
      evalCp: cpWhite,
      parent: parent,
      moveProbability: 0.3,
      cumulativeProbability: 0.3,
    );
  }

  reply(e4, 'e5', 'e4e5', 30);
  reply(e4, 'c5', 'e4c5', 31);
  reply(e4, 'a6', 'e4a6', 110);
  reply(d4, 'd5', 'd4d5', 29);
  reply(d4, 'h5', 'd4h5', 119);
  return (root: root, e4: e4, d4: d4);
}

BuildTreeNode _pick(TreeBuildConfig config, BuildTreeNode root) {
  final tree = BuildTree(root: root);
  RepertoireSelector(
    config: config,
    ecaCalc: ExpectimaxCalculator(config: config),
  ).select(tree);
  return root.children.singleWhere((c) => c.isRepertoireMove);
}

void main() {
  test('goodReplyCount reads the opponent side of the evals', () {
    final t = _tree();
    expect(goodReplyCount(t.e4, 20, playAsWhite: true), 2);
    expect(goodReplyCount(t.d4, 20, playAsWhite: true), 1);
    expect(goodReplyCount(t.e4, 100, playAsWhite: true), 3);
    final leaf = makeNode(
      fen: _afterE4,
      san: 'e4',
      ply: 1,
      isWhiteToMove: false,
    );
    expect(goodReplyCount(leaf, 20, playAsWhite: true), isNull);
  });

  test('off, expectimax value decides', () {
    expect(_pick(_base, _tree().root).moveSan, 'e4');
  });

  test('on, the narrower candidate wins inside the eval guard', () {
    expect(
      _pick(_base.copyWith(replyWindowCp: 20), _tree().root).moveSan,
      'd4',
    );
  });

  test('a candidate outside the eval guard is never promoted', () {
    final t = _tree();
    t.d4.engineEvalCp = 40; // +(-40) for White: 70cp behind e4.
    expect(_pick(_base.copyWith(replyWindowCp: 20), t.root).moveSan, 'e4');
  });

  test('equal counts leave the mode pick alone', () {
    final t = _tree();
    t.e4.children.removeWhere((c) => c.moveSan == 'c5');
    expect(_pick(_base.copyWith(replyWindowCp: 20), t.root).moveSan, 'e4');
  });

  test('unexpanded candidates cannot be compared', () {
    final t = _tree();
    t.e4.children.clear();
    t.d4.children.clear();
    expect(_pick(_base.copyWith(replyWindowCp: 20), t.root).moveSan, 'e4');
  });
}
