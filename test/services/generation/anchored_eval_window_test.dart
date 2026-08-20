/// Regression: with `relativeEval`, the build shifts the eval window by the
/// root eval, but post-build selection used to receive the *unshifted*
/// config.  For Black (root eval negative) every node then failed the
/// selector's `evalUs <= minEvalCp` guard and a 7,000-node tree exported a
/// single stub line.  `TreeBuildConfig.anchoredToRoot` is the one shift both
/// sides now share.
library;

import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generation_test_helpers.dart';

// Benko, after 5.bxa6 e6: White to move, +57 for White (= -57 for us).
const _kRootFen =
    'rnbqkb1r/3p1ppp/P3pn2/2pP4/8/8/PP2PPPP/RNBQKBNR w KQkq - 0 6';
const _kAfterDxe6 =
    'rnbqkb1r/3p1ppp/P3Pn2/2p5/8/8/PP2PPPP/RNBQKBNR b KQkq - 0 6';
const _kAfterFxe6 =
    'rnbqkb1r/3p2pp/P3pn2/2p5/8/8/PP2PPPP/RNBQKBNR w KQkq - 0 7';
const _kAfterFxe6Nf3 =
    'rnbqkb1r/3p2pp/P3pn2/2p5/8/5N2/PP2PPPP/RNBQKB1R b KQkq - 1 7';

/// A tiny Black tree whose evals are all a little worse than equal — the
/// normal shape of a gambit repertoire.  Evals are side-to-move relative.
BuildTree _blackGambitTree() {
  resetNodeIds();
  final root = makeNode(
    fen: _kRootFen,
    san: '',
    ply: 0,
    isWhiteToMove: true,
    evalCp: 57,
  );
  final dxe6 = makeNode(
    fen: _kAfterDxe6,
    san: 'dxe6',
    uci: 'd5e6',
    ply: 1,
    isWhiteToMove: false,
    evalCp: -52,
    moveProbability: 0.19,
    cumulativeProbability: 0.19,
    parent: root,
  );
  final fxe6 = makeNode(
    fen: _kAfterFxe6,
    san: 'fxe6',
    uci: 'f7e6',
    ply: 2,
    isWhiteToMove: true,
    evalCp: 52,
    cumulativeProbability: 0.19,
    parent: dxe6,
  );
  makeNode(
    fen: _kAfterFxe6Nf3,
    san: 'Nf3',
    uci: 'g1f3',
    ply: 3,
    isWhiteToMove: false,
    evalCp: -33,
    moveProbability: 0.29,
    cumulativeProbability: 0.055,
    parent: fxe6,
  );
  for (final n in [dxe6, fxe6]) {
    n
      ..expectimaxValue = 0.45
      ..hasExpectimax = true;
  }
  return BuildTree(root: root);
}

int _selectedCount(BuildTree tree, TreeBuildConfig config) {
  final selector = RepertoireSelector(
    config: config,
    ecaCalc: ExpectimaxCalculator(config: config),
  );
  return selector.select(tree);
}

void main() {
  group('TreeBuildConfig.anchoredToRoot', () {
    test('shifts both bounds by the root eval for us', () {
      final tree = _blackGambitTree();
      const config = TreeBuildConfig(
        startFen: _kRootFen,
        playAsWhite: false,
        minEvalCp: 0,
        maxEvalCp: 200,
      );
      final anchored = config.anchoredToRoot(tree.root);
      expect(anchored.minEvalCp, -57);
      expect(anchored.maxEvalCp, 143);
    });

    test('is the identity without relativeEval or without a root eval', () {
      final tree = _blackGambitTree();
      const absolute = TreeBuildConfig(
        startFen: _kRootFen,
        playAsWhite: false,
        relativeEval: false,
      );
      expect(identical(absolute.anchoredToRoot(tree.root), absolute), isTrue);

      tree.root.engineEvalCp = null;
      const relative = TreeBuildConfig(startFen: _kRootFen, playAsWhite: false);
      expect(identical(relative.anchoredToRoot(tree.root), relative), isTrue);
    });
  });

  group('selection under the anchored window', () {
    test('a Black gambit tree selects nothing under the raw window', () {
      // Documents the failure mode: root at -57 for us, floor 0.
      const raw = TreeBuildConfig(startFen: _kRootFen, playAsWhite: false);
      expect(_selectedCount(_blackGambitTree(), raw), 0);
    });

    test('the same tree selects its reply under the anchored window', () {
      final tree = _blackGambitTree();
      const raw = TreeBuildConfig(startFen: _kRootFen, playAsWhite: false);
      final count = _selectedCount(tree, raw.anchoredToRoot(tree.root));
      expect(count, 1);
      final fxe6 = tree.root.children.single.children.single;
      expect(fxe6.moveSan, 'fxe6');
      expect(fxe6.isRepertoireMove, isTrue);
    });
  });

  group('TreeBuildConfig.formDefaults', () {
    test('gives both colours the same window, because it is an offset', () {
      final black = TreeBuildConfig.formDefaults(
        startFen: _kRootFen,
        playAsWhite: false,
      );
      final white = TreeBuildConfig.formDefaults(
        startFen: _kRootFen,
        playAsWhite: true,
      );

      // relativeEval is on by default, so these are offsets from the root's
      // own eval and a colour split would be meaningless. The old White floor
      // of 0 read as an offset meant "never prepare anything worse than the
      // start", which rules out every gambit.
      expect(white.relativeEval, isTrue);
      expect(black.minEvalCp, white.minEvalCp);
      expect(black.maxEvalCp, white.maxEvalCp);
      expect(white.minEvalCp, -100);
      expect(white.maxEvalCp, 200);
      expect(black.maxEvalLossCp, 30);
    });

    test('the same offsets land in different places for different roots', () {
      // What "relative" buys: one setting, whatever position you hand it.
      final config = TreeBuildConfig.formDefaults(
        startFen: _kRootFen,
        playAsWhite: true,
      );

      final level = makeNode(
        fen: _kRootFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
        evalCp: 0,
      );
      final better = makeNode(
        fen: _kRootFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
        evalCp: 60,
      );

      expect(config.anchoredToRoot(level).minEvalCp, -100);
      expect(config.anchoredToRoot(better).minEvalCp, -40);
      expect(config.anchoredToRoot(level).maxEvalCp, 200);
      expect(config.anchoredToRoot(better).maxEvalCp, 260);
    });
  });
}
