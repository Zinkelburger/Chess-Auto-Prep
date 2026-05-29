import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import 'package:flutter_test/flutter_test.dart';

CoverageResult _emptyCoverageResult() {
  return CoverageResult(
    rootFen: 'startpos',
    rootMoves: const [],
    rootGameCount: 0,
    targetPercent: 80,
    targetGameCount: 0,
    coveredLeaves: const [],
    tooShallowLeaves: const [],
    tooDeepLeaves: const [],
    unaccountedMoves: const [],
    totalCoveredGames: 0,
    totalShallowGames: 0,
    totalDeepGames: 0,
    totalUnaccountedGames: 0,
  );
}

CoverageResult _coverageResult({
  List<LeafNode> coveredLeaves = const [],
  List<LeafNode> tooShallowLeaves = const [],
  List<UnaccountedMove> unaccountedMoves = const [],
}) {
  final totalCovered =
      coveredLeaves.fold<int>(0, (sum, leaf) => sum + leaf.gameCount);
  final totalShallow =
      tooShallowLeaves.fold<int>(0, (sum, leaf) => sum + leaf.gameCount);
  final totalUnaccounted =
      unaccountedMoves.fold<int>(0, (sum, move) => sum + move.gameCount);

  return CoverageResult(
    rootFen: 'startpos',
    rootMoves: const ['e4'],
    rootGameCount: 1000,
    targetPercent: 80,
    targetGameCount: 800,
    coveredLeaves: coveredLeaves,
    tooShallowLeaves: tooShallowLeaves,
    tooDeepLeaves: const [],
    unaccountedMoves: unaccountedMoves,
    totalCoveredGames: totalCovered,
    totalShallowGames: totalShallow,
    totalDeepGames: 0,
    totalUnaccountedGames: totalUnaccounted,
  );
}

void main() {
  group('CoverageResult.findNextGap', () {
    test('findNextGap on fully covered tree returns null', () {
      final result = _coverageResult(
        coveredLeaves: [
          LeafNode(
            fen: 'fen1',
            moves: ['e4', 'e5'],
            gameCount: 500,
            category: LeafCategory.covered,
            reason: 'covered',
          ),
        ],
      );

      expect(result.findNextGap(), isNull);
    });

    test('findNextGap returns shallowest uncovered position', () {
      final result = _coverageResult(
        tooShallowLeaves: [
          LeafNode(
            fen: 'deep',
            moves: ['e4', 'e5', 'Nf3', 'Nc6'],
            gameCount: 200,
            category: LeafCategory.tooShallow,
            reason: 'too shallow',
          ),
          LeafNode(
            fen: 'medium',
            moves: ['e4', 'c5'],
            gameCount: 150,
            category: LeafCategory.tooShallow,
            reason: 'too shallow',
          ),
        ],
        unaccountedMoves: [
          UnaccountedMove(
            parentMoves: const [],
            move: 'd4',
            gameCount: 100,
            probability: 0.1,
            source: 'lichess',
          ),
        ],
      );

      expect(result.findNextGap(), ['d4']);
    });

    test('both return null on empty result', () {
      final result = _emptyCoverageResult();

      expect(result.findNextGap(), isNull);
      expect(result.findBiggestGap(), isNull);
    });
  });

  group('CoverageResult.findBiggestGap', () {
    test('findBiggestGap returns position with highest game count', () {
      final result = _coverageResult(
        tooShallowLeaves: [
          LeafNode(
            fen: 'small',
            moves: ['e4', 'c5'],
            gameCount: 50,
            category: LeafCategory.tooShallow,
            reason: 'too shallow',
          ),
          LeafNode(
            fen: 'large',
            moves: ['e4', 'e5', 'Nf3'],
            gameCount: 400,
            category: LeafCategory.tooShallow,
            reason: 'too shallow',
          ),
        ],
        unaccountedMoves: [
          UnaccountedMove(
            parentMoves: ['e4', 'e5'],
            move: 'c5',
            gameCount: 250,
            probability: 0.25,
            source: 'lichess',
          ),
        ],
      );

      expect(result.findBiggestGap(), ['e4', 'e5', 'Nf3']);
    });
  });
}
