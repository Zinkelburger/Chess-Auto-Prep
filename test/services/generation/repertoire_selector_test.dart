import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:flutter_test/flutter_test.dart';

BuildTreeNode _node({
  required String fen,
  required String san,
  required String uci,
  required int ply,
  required bool isWhiteToMove,
  double expectimax = 0.5,
  int? evalCp,
  bool hasExpectimax = true,
  double cumulativeProbability = 1.0,
}) {
  final node = BuildTreeNode(
    fen: fen,
    moveSan: san,
    moveUci: uci,
    ply: ply,
    isWhiteToMove: isWhiteToMove,
    nodeId: '$san@$ply'.hashCode,
    cumulativeProbability: cumulativeProbability,
  )
    ..expectimaxValue = expectimax
    ..hasExpectimax = hasExpectimax;
  if (evalCp != null) {
    node.engineEvalCp = evalCp;
  }
  return node;
}

BuildTree _twoBranchTree() {
  final root = _node(
    fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    san: '',
    uci: '',
    ply: 0,
    isWhiteToMove: true,
  );

  final e4 = _node(
    fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
    san: 'e4',
    uci: 'e2e4',
    ply: 1,
    isWhiteToMove: false,
    expectimax: 0.72,
    evalCp: -35,
  );
  final d4 = _node(
    fen: 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1',
    san: 'd4',
    uci: 'd2d4',
    ply: 1,
    isWhiteToMove: false,
    expectimax: 0.55,
    evalCp: -20,
  );

  final e4e5 = _node(
    fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
    san: 'e5',
    uci: 'e7e5',
    ply: 2,
    isWhiteToMove: true,
    expectimax: 0.70,
    evalCp: -30,
    cumulativeProbability: 0.4,
  );
  final d4d5 = _node(
    fen: 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1',
    san: 'd5',
    uci: 'd7d5',
    ply: 2,
    isWhiteToMove: true,
    expectimax: 0.52,
    evalCp: -15,
    cumulativeProbability: 0.35,
  );

  e4.children.add(e4e5);
  d4.children.add(d4d5);
  root.children.addAll([e4, d4]);

  e4.parent = root;
  d4.parent = root;
  e4e5.parent = e4;
  d4d5.parent = d4;

  return BuildTree(root: root);
}

List<BuildTreeNode> _markedOurMoves(BuildTree tree) {
  final marked = <BuildTreeNode>[];
  void walk(BuildTreeNode node) {
    if (node.isRepertoireMove) marked.add(node);
    for (final child in node.children) {
      walk(child);
    }
  }

  walk(tree.root);
  return marked;
}

void main() {
  group('RepertoireSelector', () {
    test('select with expectimax mode marks highest-V child at our-move nodes',
        () {
      final tree = _twoBranchTree();
      final config = const TreeBuildConfig(
        startFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        playAsWhite: true,
        selectionMode: SelectionMode.expectimax,
      );
      final selector = RepertoireSelector(
        config: config,
        ecaCalc: ExpectimaxCalculator(config: config),
      );

      selector.select(tree);

      final marked = _markedOurMoves(tree);
      expect(marked.map((n) => n.moveSan), ['e4']);
      expect(marked.single.repertoireScore, closeTo(0.72, 0.0001));
    });

    test('select with engineOnly mode marks best-eval child', () {
      final tree = _twoBranchTree();
      final config = const TreeBuildConfig(
        startFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        playAsWhite: true,
        selectionMode: SelectionMode.engineOnly,
      );
      final selector = RepertoireSelector(
        config: config,
        ecaCalc: ExpectimaxCalculator(config: config),
      );

      selector.select(tree);

      expect(_markedOurMoves(tree).map((n) => n.moveSan), ['e4']);
    });

    test('coverage floor: rare-but-popular reply below minProbability '
        'still gets a repertoire answer', () {
      BuildTree makeTree() {
        final root = _node(
          fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
          san: '',
          uci: '',
          ply: 0,
          isWhiteToMove: true,
        );
        final e4 = _node(
          fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
          san: 'e4',
          uci: 'e2e4',
          ply: 1,
          isWhiteToMove: false,
          expectimax: 0.7,
          evalCp: -35,
        );
        // Deep sideline: reach probability below the 0.01 floor, but the
        // reply itself is played 20% of the time locally.
        final rare = _node(
          fen: 'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
          san: 'c5',
          uci: 'c7c5',
          ply: 2,
          isWhiteToMove: true,
          expectimax: 0.6,
          evalCp: 30,
          cumulativeProbability: 0.001,
        )..moveProbability = 0.20;
        final answer = _node(
          fen: 'rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2',
          san: 'Nf3',
          uci: 'g1f3',
          ply: 3,
          isWhiteToMove: false,
          expectimax: 0.6,
          evalCp: -30,
          cumulativeProbability: 0.001,
        );
        root.children.add(e4);
        e4.children.add(rare);
        rare.children.add(answer);
        e4.parent = root;
        rare.parent = e4;
        answer.parent = rare;
        return BuildTree(root: root);
      }

      const base = TreeBuildConfig(
        startFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        playAsWhite: true,
        minProbability: 0.01,
      );

      // Coverage floor active (default 0.05 < 0.20): answer is selected.
      final covered = makeTree();
      RepertoireSelector(
        config: base,
        ecaCalc: ExpectimaxCalculator(config: base),
      ).select(covered);
      expect(
        _markedOurMoves(covered).map((n) => n.moveSan),
        contains('Nf3'),
      );

      // Coverage floor disabled: legacy prune drops the sideline.
      final uncovered = makeTree();
      final legacy = base.copyWith(coverMinProb: 0.0);
      RepertoireSelector(
        config: legacy,
        ecaCalc: ExpectimaxCalculator(config: legacy),
      ).select(uncovered);
      expect(
        _markedOurMoves(uncovered).map((n) => n.moveSan),
        isNot(contains('Nf3')),
      );
    });

    test('preferred setup: tie-break within tolerance, deviate beyond it',
        () {
      // Root (our turn, White): e4 has the better expectimax, h4 is the
      // setup move.  Within tolerance → h4 preferred; beyond → e4 stands.
      BuildTree makeTree({required int h4Cp}) {
        final root = _node(
          fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
          san: '',
          uci: '',
          ply: 0,
          isWhiteToMove: true,
        );
        final e4 = _node(
          fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
          san: 'e4',
          uci: 'e2e4',
          ply: 1,
          isWhiteToMove: false,
          expectimax: 0.72,
          evalCp: -35, // +35 for White (STM-relative)
        );
        final h4 = _node(
          fen: 'rnbqkbnr/pppppppp/8/8/7P/8/PPPPPPP1/RNBQKBNR b KQkq - 0 1',
          san: 'h4',
          uci: 'h2h4',
          ply: 1,
          isWhiteToMove: false,
          expectimax: 0.60,
          evalCp: -h4Cp, // h4Cp for White
        );
        root.children.addAll([e4, h4]);
        e4.parent = root;
        h4.parent = root;
        return BuildTree(root: root);
      }

      const config = TreeBuildConfig(
        startFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        playAsWhite: true,
        setupMoves: 'h4 Nh3',
        setupToleranceCp: 30,
      );

      // h4 loses 20cp vs e4 (within 30cp tolerance) → setup move chosen.
      final within = makeTree(h4Cp: 15);
      RepertoireSelector(
        config: config,
        ecaCalc: ExpectimaxCalculator(config: config),
      ).select(within);
      expect(_markedOurMoves(within).map((n) => n.moveSan), ['h4']);

      // h4 loses 75cp (beyond tolerance) → eval guard deviates to e4.
      final beyond = makeTree(h4Cp: -40);
      RepertoireSelector(
        config: config,
        ecaCalc: ExpectimaxCalculator(config: config),
      ).select(beyond);
      expect(_markedOurMoves(beyond).map((n) => n.moveSan), ['e4']);

      // No setup configured → plain expectimax pick.
      final off = makeTree(h4Cp: 15);
      final plain = config.copyWith(setupMoves: '');
      RepertoireSelector(
        config: plain,
        ecaCalc: ExpectimaxCalculator(config: plain),
      ).select(off);
      expect(_markedOurMoves(off).map((n) => n.moveSan), ['e4']);
    });

    test('select is idempotent — running twice produces same markings', () {
      final tree = _twoBranchTree();
      final config = const TreeBuildConfig(
        startFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        playAsWhite: true,
        selectionMode: SelectionMode.expectimax,
      );
      final selector = RepertoireSelector(
        config: config,
        ecaCalc: ExpectimaxCalculator(config: config),
      );

      selector.select(tree);
      final firstPass = _markedOurMoves(tree)
          .map((n) => (n.moveSan, n.repertoireScore))
          .toList();

      selector.select(tree);
      final secondPass = _markedOurMoves(tree)
          .map((n) => (n.moveSan, n.repertoireScore))
          .toList();

      expect(secondPass, firstPass);
    });
  });
}
