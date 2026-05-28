import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/candidate_service.dart';

BuildTreeNode _makeNode(String fen, String san, String uci, {
  double ease = 0.5,
  double myEase = -1,
  double expectimax = 0.5,
  bool isRepertoire = false,
  int totalGames = 100,
  double moveProbability = 0.3,
  double trapScore = 0,
  int? evalCp,
  int ply = 1,
}) {
  final node = BuildTreeNode(
    fen: fen,
    moveSan: san,
    moveUci: uci,
    ply: ply,
    isWhiteToMove: ply % 2 == 0,
    nodeId: fen.hashCode,
  )
    ..ease = ease
    ..myEase = myEase
    ..expectimaxValue = expectimax
    ..isRepertoireMove = isRepertoire
    ..totalGames = totalGames
    ..moveProbability = moveProbability
    ..trapScore = trapScore;

  if (evalCp != null) {
    node.engineEvalCp = evalCp;
  }

  return node;
}

BuildTreeNode _makeRoot(String fen) {
  return BuildTreeNode(
    fen: fen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: true,
    nodeId: fen.hashCode,
  );
}

void main() {
  group('CandidateService', () {
    test('getTreeCandidates returns children of matching node', () {
      final root = _makeRoot('startpos');
      final child1 = _makeNode('fen1', 'e4', 'e2e4',
          expectimax: 0.6, isRepertoire: true, evalCp: 30);
      final child2 = _makeNode('fen2', 'd4', 'd2d4',
          expectimax: 0.55, evalCp: 25);

      root.children.addAll([child1, child2]);

      final tree = BuildTree(root: root);
      final service = CandidateService(tree: tree);

      final candidates = service.getTreeCandidates(
        fen: 'startpos',
        isOurTurn: true,
        playAsWhite: true,
      );

      expect(candidates.length, 2);
      expect(candidates.first.san, 'e4');
      expect(candidates.first.isRepertoireMove, true);
    });

    test('sorts by expectimax on our turn (repertoire first)', () {
      final root = _makeRoot('startpos');
      final child1 = _makeNode('f1', 'Nf3', 'g1f3',
          expectimax: 0.7, isRepertoire: false);
      final child2 = _makeNode('f2', 'e4', 'e2e4',
          expectimax: 0.65, isRepertoire: true);
      final child3 = _makeNode('f3', 'd4', 'd2d4',
          expectimax: 0.8, isRepertoire: false);

      root.children.addAll([child1, child2, child3]);

      final tree = BuildTree(root: root);
      final service = CandidateService(tree: tree);

      final candidates = service.getTreeCandidates(
        fen: 'startpos',
        isOurTurn: true,
        playAsWhite: true,
      );

      expect(candidates.first.san, 'e4');
      expect(candidates.first.isRepertoireMove, true);
    });

    test('sorts by frequency on opponent turn', () {
      final root = _makeRoot('startpos');
      final child1 = _makeNode('f1', 'e5', 'e7e5',
          moveProbability: 0.4, totalGames: 400);
      final child2 = _makeNode('f2', 'd5', 'd7d5',
          moveProbability: 0.3, totalGames: 300);
      final child3 = _makeNode('f3', 'c5', 'c7c5',
          moveProbability: 0.2, totalGames: 200);

      root.children.addAll([child1, child2, child3]);

      final tree = BuildTree(root: root);
      final service = CandidateService(tree: tree);

      final candidates = service.getTreeCandidates(
        fen: 'startpos',
        isOurTurn: false,
        playAsWhite: true,
      );

      expect(candidates.first.san, 'e5');
      expect(candidates.first.dbFrequency, 0.4);
    });

    test('returns empty for null tree', () {
      final service = CandidateService();
      expect(
        service.getTreeCandidates(
          fen: 'startpos',
          isOurTurn: true,
          playAsWhite: true,
        ),
        isEmpty,
      );
    });

    test('counts traps in subtree', () {
      final root = _makeRoot('startpos');
      final child = _makeNode('f1', 'e4', 'e2e4');
      final grandchild1 = _makeNode('f2', 'e5', 'e7e5',
          trapScore: 0.5, ply: 2);
      final grandchild2 = _makeNode('f3', 'c5', 'c7c5',
          trapScore: 0.3, ply: 2);
      child.children.addAll([grandchild1, grandchild2]);
      root.children.add(child);

      final tree = BuildTree(root: root);
      final service = CandidateService(tree: tree);

      final candidates = service.getTreeCandidates(
        fen: 'startpos',
        isOurTurn: true,
        playAsWhite: true,
      );

      expect(candidates.first.subtreeTrapCount, 2);
    });

    test('finds node by BFS when fenMap is null', () {
      final root = _makeRoot('startpos');
      final child = _makeNode('f1', 'e4', 'e2e4');
      final grandchild = _makeNode('target', 'e5', 'e7e5', ply: 2);
      final leaf = _makeNode('leaf', 'Nf3', 'g1f3', ply: 3);
      grandchild.children.add(leaf);
      child.children.add(grandchild);
      root.children.add(child);

      final tree = BuildTree(root: root);
      final service = CandidateService(tree: tree);

      final candidates = service.getTreeCandidates(
        fen: 'target',
        isOurTurn: true,
        playAsWhite: true,
      );

      expect(candidates.length, 1);
      expect(candidates.first.san, 'Nf3');
    });
  });
}
