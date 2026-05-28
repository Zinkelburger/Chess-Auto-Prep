import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_suggestion_service.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/coherence_service.dart';
import 'package:chess_auto_prep/services/fp_growth.dart';

BuildTreeNode _makeNode(
  String fen,
  String san,
  String uci, {
  bool isRepertoire = false,
  double expectimax = 0.5,
  double myEase = 0.6,
  int? evalCp,
  int ply = 1,
  double trapScore = 0,
}) {
  final node = BuildTreeNode(
    fen: fen,
    moveSan: san,
    moveUci: uci,
    ply: ply,
    isWhiteToMove: ply % 2 == 0,
    nodeId: '$san@$fen'.hashCode,
  )
    ..isRepertoireMove = isRepertoire
    ..expectimaxValue = expectimax
    ..myEase = myEase
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

CoverageResult _coverageWithShallowGap({
  required List<String> gapMoves,
  required String gapFen,
  int gameCount = 100,
}) {
  return CoverageResult(
    rootFen: 'startpos',
    rootMoves: const [],
    rootGameCount: 1000,
    targetPercent: 80,
    targetGameCount: 800,
    coveredLeaves: const [],
    tooShallowLeaves: [
      LeafNode(
        fen: gapFen,
        moves: gapMoves,
        gameCount: gameCount,
        category: LeafCategory.tooShallow,
        reason: 'too shallow',
      ),
    ],
    tooDeepLeaves: const [],
    unaccountedMoves: const [],
    totalCoveredGames: 500,
    totalShallowGames: gameCount,
    totalDeepGames: 0,
    totalUnaccountedGames: 0,
  );
}

CoherenceResult _coherenceWithItemset(FrequentItemset itemset) {
  return CoherenceResult(
    globalCoherence: 0.7,
    riskWeightedCoherence: 0.65,
    clusters: const [],
    lineCoherenceById: const {},
    maximalItemsets: [itemset],
    topNCoverage: 0.5,
  );
}

BuildTree _treeForGap(List<String> gapMoves) {
  final root = _makeRoot('startpos');
  var current = root;
  var ply = 1;

  for (var i = 0; i < gapMoves.length; i++) {
    final san = gapMoves[i];
    final child = _makeNode(
      'fen_$san',
      san,
      san,
      ply: ply,
      isRepertoire: i.isEven,
      expectimax: 0.6,
      evalCp: 30,
    );
    current.children.add(child);
    current = child;
    ply++;
  }

  final nf3 = _makeNode(
    'fen_nf3',
    'Nf3',
    'Nf3',
    ply: ply,
    isRepertoire: true,
    expectimax: 0.7,
    evalCp: 40,
  );
  current.children.add(nf3);
  final nc6 = _makeNode(
    'fen_nc6',
    'Nc6',
    'Nc6',
    ply: ply + 1,
    isRepertoire: false,
    expectimax: 0.55,
    evalCp: 35,
  );
  nf3.children.add(nc6);

  return BuildTree(root: root);
}

void main() {
  group('CoverageSuggestionService coherenceBonus', () {
    test('populates coherenceBonus from lineCoherence when coherence provided',
        () {
      const gapMoves = ['e4', 'e5'];
      final tree = _treeForGap(gapMoves);
      final coverage = _coverageWithShallowGap(
        gapMoves: gapMoves,
        gapFen: 'fen_e5',
      );
      final coherence = _coherenceWithItemset(
        const FrequentItemset(
          items: {'e4', 'Nf3'},
          support: 0.6,
          count: 6,
        ),
      );

      final service = CoverageSuggestionService(
        coverage: coverage,
        tree: tree,
        coherence: coherence,
      );

      final suggestions = service.generateSuggestions(
        targetCoverage: 60,
        playAsWhite: true,
      );

      expect(suggestions, isNotEmpty);
      expect(suggestions.first.coherenceBonus, isNotNull);
      expect(suggestions.first.coherenceBonus, greaterThan(0));
      expect(suggestions.first.fullMoves, contains('Nf3'));
    });

    test('leaves coherenceBonus null without coherence result', () {
      const gapMoves = ['e4', 'e5'];
      final tree = _treeForGap(gapMoves);
      final coverage = _coverageWithShallowGap(
        gapMoves: gapMoves,
        gapFen: 'fen_e5',
      );

      final service = CoverageSuggestionService(
        coverage: coverage,
        tree: tree,
      );

      final suggestions = service.generateSuggestions(
        targetCoverage: 60,
        playAsWhite: true,
      );

      expect(suggestions, isNotEmpty);
      expect(suggestions.first.coherenceBonus, isNull);
    });

    test('coherenceExp boosts score for coherent lines', () {
      const gapMoves = ['e4', 'e5'];
      final tree = _treeForGap(gapMoves);
      final coverage = _coverageWithShallowGap(
        gapMoves: gapMoves,
        gapFen: 'fen_e5',
      );
      final coherent = _coherenceWithItemset(
        const FrequentItemset(
          items: {'e4', 'Nf3'},
          support: 0.9,
          count: 9,
        ),
      );
      final incoherent = _coherenceWithItemset(
        const FrequentItemset(
          items: {'d4', 'c4'},
          support: 0.9,
          count: 9,
        ),
      );

      final coherentService = CoverageSuggestionService(
        coverage: coverage,
        tree: tree,
        coherence: coherent,
      );
      final incoherentService = CoverageSuggestionService(
        coverage: coverage,
        tree: tree,
        coherence: incoherent,
      );

      const weights = SuggestionWeights(coherenceExp: 1.0);

      final coherentScore = coherentService
          .generateSuggestions(
            targetCoverage: 60,
            playAsWhite: true,
            weights: weights,
          )
          .first
          .score;
      final incoherentScore = incoherentService
          .generateSuggestions(
            targetCoverage: 60,
            playAsWhite: true,
            weights: weights,
          )
          .first
          .score;

      expect(coherentScore, greaterThan(incoherentScore));
    });

    test('default coherenceExp does not change score multiplier', () {
      const gapMoves = ['e4', 'e5'];
      final tree = _treeForGap(gapMoves);
      final coverage = _coverageWithShallowGap(
        gapMoves: gapMoves,
        gapFen: 'fen_e5',
      );
      final coherence = _coherenceWithItemset(
        const FrequentItemset(
          items: {'e4', 'Nf3'},
          support: 0.9,
          count: 9,
        ),
      );

      final withCoherence = CoverageSuggestionService(
        coverage: coverage,
        tree: tree,
        coherence: coherence,
      );
      final withoutCoherence = CoverageSuggestionService(
        coverage: coverage,
        tree: tree,
      );

      final scoreWith = withCoherence
          .generateSuggestions(
            targetCoverage: 60,
            playAsWhite: true,
          )
          .first
          .score;
      final scoreWithout = withoutCoherence
          .generateSuggestions(
            targetCoverage: 60,
            playAsWhite: true,
          )
          .first
          .score;

      expect(scoreWith, closeTo(scoreWithout, 0.0001));
    });
  });
}
