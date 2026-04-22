import 'package:chess_auto_prep/models/build_tree_node.dart';

BuildTree makeEvalTreeTestTree() {
  var nextNodeId = 1;

  BuildTreeNode makeNode({
    required String fen,
    required String moveSan,
    required String moveUci,
    required int ply,
    required bool isWhiteToMove,
    BuildTreeNode? parent,
  }) {
    return BuildTreeNode(
      fen: fen,
      moveSan: moveSan,
      moveUci: moveUci,
      ply: ply,
      isWhiteToMove: isWhiteToMove,
      nodeId: nextNodeId++,
      parent: parent,
    );
  }

  final root = makeNode(
    fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: true,
  )
    ..engineEvalCp = 25
    ..setLichessStats(55, 30, 15)
    ..explored = true
    ..hasExpectimax = true
    ..expectimaxValue = 0.58;

  final d4 = makeNode(
    fen: 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1',
    moveSan: 'd4',
    moveUci: 'd2d4',
    ply: 1,
    isWhiteToMove: false,
    parent: root,
  )
    ..moveProbability = 0.7
    ..cumulativeProbability = 1.0
    ..engineEvalCp = -15
    ..setLichessStats(24, 18, 8)
    ..explored = true
    ..hasExpectimax = true
    ..expectimaxValue = 0.51
    ..localCpl = 6;

  final e4 = makeNode(
    fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
    moveSan: 'e4',
    moveUci: 'e2e4',
    ply: 1,
    isWhiteToMove: false,
    parent: root,
  )
    ..moveProbability = 0.3
    ..cumulativeProbability = 1.0
    ..engineEvalCp = -30
    ..setLichessStats(42, 12, 6)
    ..explored = true
    ..hasExpectimax = true
    ..expectimaxValue = 0.63
    ..localCpl = 18
    ..trapScore = 0.32
    ..isRepertoireMove = true;

  root.children.addAll([d4, e4]);

  final d5 = makeNode(
    fen: 'rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq d6 0 2',
    moveSan: 'd5',
    moveUci: 'd7d5',
    ply: 2,
    isWhiteToMove: true,
    parent: d4,
  )
    ..moveProbability = 0.62
    ..cumulativeProbability = 0.62
    ..engineEvalCp = 5
    ..setLichessStats(18, 14, 4)
    ..explored = true
    ..hasExpectimax = true
    ..expectimaxValue = 0.49;

  d4.children.add(d5);

  final c5 = makeNode(
    fen: 'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2',
    moveSan: 'c5',
    moveUci: 'c7c5',
    ply: 2,
    isWhiteToMove: true,
    parent: e4,
  )
    ..moveProbability = 0.42
    ..cumulativeProbability = 0.42
    ..engineEvalCp = 35
    ..setLichessStats(16, 10, 3)
    ..explored = true
    ..hasExpectimax = true
    ..expectimaxValue = 0.57;

  final e5 = makeNode(
    fen: 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2',
    moveSan: 'e5',
    moveUci: 'e7e5',
    ply: 2,
    isWhiteToMove: true,
    parent: e4,
  )
    ..moveProbability = 0.58
    ..cumulativeProbability = 0.58
    ..engineEvalCp = 10
    ..setLichessStats(28, 14, 6)
    ..explored = true
    ..hasExpectimax = true
    ..expectimaxValue = 0.61;

  e4.children.addAll([c5, e5]);

  final nf3 = makeNode(
    fen: 'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2',
    moveSan: 'Nf3',
    moveUci: 'g1f3',
    ply: 3,
    isWhiteToMove: false,
    parent: e5,
  )
    ..moveProbability = 1.0
    ..cumulativeProbability = 0.58
    ..engineEvalCp = -40
    ..setLichessStats(20, 8, 4)
    ..explored = true
    ..hasExpectimax = true
    ..expectimaxValue = 0.66
    ..isRepertoireMove = true;

  final bc4 = makeNode(
    fen: 'rnbqkbnr/pppp1ppp/8/4p3/2B1P3/8/PPPP1PPP/RNBQK1NR b KQkq - 1 2',
    moveSan: 'Bc4',
    moveUci: 'f1c4',
    ply: 3,
    isWhiteToMove: false,
    parent: e5,
  )
    ..moveProbability = 0.0
    ..cumulativeProbability = 0.58
    ..engineEvalCp = -25
    ..explored = true
    ..hasExpectimax = true
    ..expectimaxValue = 0.59;

  e5.children.addAll([bc4, nf3]);

  final tree = BuildTree(
    root: root,
    totalNodes: root.countSubtree(),
    maxPlyReached: 3,
    buildComplete: true,
    configSnapshot: const {'play_as_white': true},
  );

  tree.computeMetadata();
  tree.sortAllChildren();
  return tree;
}
