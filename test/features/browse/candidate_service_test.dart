import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/models/explorer_response.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/features/browse/services/candidate_service.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';

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

    test('marks inRepertoire from OpeningTree hasMove', () {
      final root = _makeRoot(kStandardStartFen);
      final child = _makeNode('f1', 'e4', 'e2e4');
      final child2 = _makeNode('f2', 'd4', 'd2d4');
      root.children.addAll([child, child2]);

      final tree = BuildTree(root: root);
      final openingTree = OpeningTree();
      openingTree.appendLine(['e4']);

      final service = CandidateService(tree: tree, openingTree: openingTree);
      final candidates = service.getTreeCandidates(
        fen: kStandardStartFen,
        isOurTurn: true,
        playAsWhite: true,
      );

      final e4 = candidates.firstWhere((c) => c.san == 'e4');
      final d4 = candidates.firstWhere((c) => c.san == 'd4');
      expect(e4.inRepertoire, isTrue);
      expect(d4.inRepertoire, isFalse);
    });
  });

  group('mergeWithExplorer', () {
    test('enriches tree moves with W/D/B from explorer', () {
      const treeMove = CandidateMove(
        san: 'e4',
        uci: 'e2e4',
        evalCp: 30,
        evalSource: 'tree',
        dbGames: 500,
        dbFrequency: 0.5,
      );

      final explorer = ExplorerResponse.fromJson(
        {
          'moves': [
            {
              'san': 'e4',
              'uci': 'e2e4',
              'white': 400,
              'draws': 100,
              'black': 400,
            },
          ],
        },
        fen: kStandardStartFen,
      );

      final merged = CandidateService.mergeWithExplorer(
        treeCandidates: [treeMove],
        explorer: explorer,
        fen: kStandardStartFen,
        isOurTurn: false,
        openingTree: null,
        coverage: null,
        pathFromRoot: const [],
      );

      expect(merged.length, 1);
      expect(merged.first.dbGames, 900);
      expect(merged.first.dbWhiteWin, closeTo(400 / 900, 0.001));
      expect(merged.first.dbDraw, closeTo(100 / 900, 0.001));
      expect(merged.first.dbBlackWin, closeTo(400 / 900, 0.001));
      expect(merged.first.evalCp, 30);
    });

    test('adds DB-only moves not present in tree', () {
      const treeMove = CandidateMove(
        san: 'e4',
        uci: 'e2e4',
        evalSource: 'tree',
      );

      final explorer = ExplorerResponse.fromJson(
        {
          'moves': [
            {
              'san': 'e4',
              'uci': 'e2e4',
              'white': 400,
              'draws': 50,
              'black': 350,
            },
            {
              'san': 'd4',
              'uci': 'd2d4',
              'white': 300,
              'draws': 30,
              'black': 270,
            },
          ],
        },
        fen: kStandardStartFen,
      );

      final merged = CandidateService.mergeWithExplorer(
        treeCandidates: [treeMove],
        explorer: explorer,
        fen: kStandardStartFen,
        isOurTurn: false,
        openingTree: null,
        coverage: null,
        pathFromRoot: const [],
      );

      expect(merged.length, 2);
      expect(merged.map((c) => c.san), containsAll(['e4', 'd4']));
      final d4 = merged.firstWhere((c) => c.san == 'd4');
      expect(d4.evalSource, 'db');
      expect(d4.evalCp, isNull);
      expect(d4.dbGames, 600);
    });

    test('returns explorer-only list when tree is empty', () {
      final explorer = ExplorerResponse.fromJson(
        {
          'moves': [
            {
              'san': 'e4',
              'uci': 'e2e4',
              'white': 400,
              'draws': 50,
              'black': 350,
            },
          ],
        },
        fen: kStandardStartFen,
      );

      final merged = CandidateService.mergeWithExplorer(
        treeCandidates: const [],
        explorer: explorer,
        fen: kStandardStartFen,
        isOurTurn: false,
        openingTree: null,
        coverage: null,
        pathFromRoot: const [],
      );

      expect(merged.length, 1);
      expect(merged.first.san, 'e4');
      expect(merged.first.evalSource, 'db');
    });
  });

  group('getCandidates async', () {
    test('DB-only fallback when no BuildTree', () async {
      final mockService = _MockCoverageService({
        kStandardStartFen: {
          'moves': [
            {
              'san': 'e4',
              'uci': 'e2e4',
              'white': 400,
              'draws': 50,
              'black': 350,
            },
            {
              'san': 'd4',
              'uci': 'd2d4',
              'white': 300,
              'draws': 30,
              'black': 270,
            },
          ],
        },
      });

      final service = CandidateService(coverageService: mockService);
      final candidates = await service.getCandidates(
        fen: kStandardStartFen,
        isOurTurn: false,
        playAsWhite: true,
      );

      expect(candidates.length, 2);
      expect(candidates.first.san, 'e4');
      expect(candidates.first.dbGames, 800);
      expect(candidates.every((c) => c.evalSource == 'db'), isTrue);
    });

    test('skips explorer when tree has DB stats', () async {
      final root = _makeRoot(kStandardStartFen);
      final child = _makeNode('f1', 'e4', 'e2e4',
          totalGames: 800, moveProbability: 0.6);
      root.children.add(child);

      final mockService = _MockCoverageService({
        kStandardStartFen: {
          'moves': [
            {
              'san': 'd4',
              'uci': 'd2d4',
              'white': 100,
              'draws': 10,
              'black': 90,
            },
          ],
        },
      });

      final service = CandidateService(
        tree: BuildTree(root: root),
        coverageService: mockService,
      );

      final candidates = await service.getCandidates(
        fen: kStandardStartFen,
        isOurTurn: false,
        playAsWhite: true,
      );

      expect(candidates.length, 1);
      expect(candidates.first.san, 'e4');
      expect(mockService.fetchCount, 0);
    });

    test('fetches explorer when tree is sparse at position', () async {
      final root = _makeRoot(kStandardStartFen);
      final child = _makeNode('f1', 'e4', 'e2e4', totalGames: 0);
      root.children.add(child);

      final mockService = _MockCoverageService({
        kStandardStartFen: {
          'moves': [
            {
              'san': 'e4',
              'uci': 'e2e4',
              'white': 400,
              'draws': 50,
              'black': 350,
            },
            {
              'san': 'd4',
              'uci': 'd2d4',
              'white': 300,
              'draws': 30,
              'black': 270,
            },
          ],
        },
      });

      final service = CandidateService(
        tree: BuildTree(root: root),
        coverageService: mockService,
      );

      final candidates = await service.getCandidates(
        fen: kStandardStartFen,
        isOurTurn: false,
        playAsWhite: true,
      );

      expect(mockService.fetchCount, 1);
      expect(candidates.length, 2);
      expect(candidates.firstWhere((c) => c.san == 'e4').dbWhiteWin,
          isNotNull);
    });
  });
}

class _MockCoverageService extends CoverageService {
  _MockCoverageService(this._responses);

  final Map<String, Map<String, dynamic>> _responses;
  int fetchCount = 0;

  @override
  Future<Map<String, dynamic>?> getPositionData(String fen) async {
    fetchCount++;
    return _responses[fen];
  }
}
