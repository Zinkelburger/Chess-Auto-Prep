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
