/// Generates prioritized line suggestions to reach a target coverage %.
///
/// Pipeline: gaps → resolve → score → greedy set-cover selection.
library;

import 'dart:math' show pow;

import 'package:dartchess/dartchess.dart';

import '../../../chess_core/generation/build_tree_node.dart';
import '../../../models/repertoire_line.dart';
import '../../../services/coherence_service.dart';
import '../../../services/generation/fen_map.dart';
import '../../../utils/ease_utils.dart' show winProbability;
import 'coverage_service.dart';

enum GapType { tooShallow, unaccounted }

class GapCandidate {
  final List<String> pathToGap;
  final String fen;
  final GapType type;
  final int gameCount;
  final double coverageImpact;
  final String? opponentMove;

  const GapCandidate({
    required this.pathToGap,
    required this.fen,
    required this.type,
    required this.gameCount,
    required this.coverageImpact,
    this.opponentMove,
  });
}

class SuggestedLine {
  const SuggestedLine({
    required this.gap,
    required this.fullMoves,
    required this.newMoves,
    required this.coverageGain,
    required this.score,
    required this.source,
    this.leafEvalCp,
    this.linePlayability,
    this.trapCount = 0,
    this.coherenceBonus,
  });

  final GapCandidate gap;
  final List<String> fullMoves;
  final List<String> newMoves;

  /// Coverage percentage points the line would add.
  final double coverageGain;
  final double score;

  /// Where the continuation came from; only `tree` today.
  final String source;
  final int? leafEvalCp;
  final double? linePlayability;
  final int trapCount;
  final double? coherenceBonus;

  SuggestedLine withScore(double score) => SuggestedLine(
    gap: gap,
    fullMoves: fullMoves,
    newMoves: newMoves,
    coverageGain: coverageGain,
    score: score,
    source: source,
    leafEvalCp: leafEvalCp,
    linePlayability: linePlayability,
    trapCount: trapCount,
    coherenceBonus: coherenceBonus,
  );
}

/// Exponents on each factor of a suggestion's score.  Every one is its own
/// knob on the panel; there are no bundled profiles.
class SuggestionWeights {
  final double impactExp;
  final double evalExp;
  final double easeExp;
  final double trapExp;
  final double coherenceExp;

  const SuggestionWeights({
    this.impactExp = 0.5,
    this.evalExp = 0.3,
    this.easeExp = 0.2,
    this.trapExp = 0.0,
    this.coherenceExp = 0.0,
  });
}

class CoverageSuggestionService {
  /// Only the biggest gaps are resolved into lines.
  static const int _maxGapsResolved = 50;

  /// How far a suggested continuation follows the tree past the gap.
  static const int _maxLineDepth = 12;

  /// Trap count at which the trap factor saturates.
  static const int _trapSaturation = 5;

  final CoverageResult coverage;
  final BuildTree? tree;
  final FenMap? fenMap;
  final CoherenceResult? coherence;

  CoverageSuggestionService({
    required this.coverage,
    this.tree,
    this.fenMap,
    this.coherence,
  });

  /// Ranked lines to add, chosen greedily until [targetCoverage] is reached.
  ///
  /// [maxSuggestions] is `null` by default: the coverage target the user set
  /// is the stopping condition, so a count limit on top of it would silently
  /// stop short of the target they asked for.
  List<SuggestedLine> generateSuggestions({
    required double targetCoverage,
    required bool playAsWhite,
    SuggestionWeights weights = const SuggestionWeights(),
    int? maxSuggestions,
  }) {
    final gaps = _collectGaps();
    final candidates = _resolveLines(gaps, playAsWhite);
    final scored = _scoreAll(candidates, weights);
    return _greedySelect(scored, targetCoverage, maxSuggestions);
  }

  List<GapCandidate> _collectGaps() {
    final gaps = <GapCandidate>[];

    for (final um in coverage.unaccountedMoves) {
      final gameCount = um.gameCount;
      gaps.add(
        GapCandidate(
          pathToGap: [...um.parentMoves, um.move],
          fen: '',
          type: GapType.unaccounted,
          gameCount: gameCount,
          coverageImpact: coverage.rootGameCount > 0
              ? gameCount / coverage.rootGameCount
              : 0,
          opponentMove: um.move,
        ),
      );
    }

    for (final leaf in coverage.tooShallowLeaves) {
      gaps.add(
        GapCandidate(
          pathToGap: leaf.moves,
          fen: leaf.fen,
          type: GapType.tooShallow,
          gameCount: leaf.gameCount,
          coverageImpact: coverage.rootGameCount > 0
              ? leaf.gameCount / coverage.rootGameCount
              : 0,
        ),
      );
    }

    gaps.sort((a, b) => b.gameCount.compareTo(a.gameCount));
    return gaps;
  }

  List<SuggestedLine> _resolveLines(
    List<GapCandidate> gaps,
    bool playAsWhite,
  ) => [
    for (final gap in gaps.take(_maxGapsResolved))
      ?_findTreePath(gap, playAsWhite),
  ];

  SuggestedLine? _findTreePath(GapCandidate gap, bool playAsWhite) {
    final tree = this.tree;
    if (tree == null) return null;

    final fenMap = this.fenMap;
    BuildTreeNode? node;
    if (gap.fen.isNotEmpty && fenMap != null) {
      node = fenMap.getCanonical(gap.fen);
    }
    node ??= _walkTree(tree.root, gap.pathToGap);
    if (node == null) return null;

    final path = <String>[...gap.pathToGap];
    var current = node;
    int trapCount = 0;

    for (
      var depth = 0;
      depth < _maxLineDepth && current.children.isNotEmpty;
      depth++
    ) {
      final repertoireChild = current.children
          .where((c) => c.isRepertoireMove)
          .toList();
      final next = repertoireChild.isNotEmpty
          ? repertoireChild.first
          : current.children.reduce(
              (a, b) => a.expectimaxValue >= b.expectimaxValue ? a : b,
            );

      path.add(next.moveSan);
      if (next.trapScore > 0) trapCount++;
      current = next;
    }

    final newMoves = path.sublist(gap.pathToGap.length);
    if (newMoves.isEmpty) return null;

    final coherenceBonus = _coherenceBonusForPath(path, playAsWhite);

    return SuggestedLine(
      gap: gap,
      fullMoves: path,
      newMoves: newMoves,
      coverageGain: gap.coverageImpact * 100,
      score: 0,
      source: 'tree',
      leafEvalCp: current.hasEngineEval ? current.evalForUs(playAsWhite) : null,
      linePlayability: current.myEase >= 0 ? current.myEase : null,
      trapCount: trapCount,
      coherenceBonus: coherenceBonus,
    );
  }

  double? _coherenceBonusForPath(List<String> moves, bool playAsWhite) {
    final coherenceResult = coherence;
    if (coherenceResult == null || coherenceResult.maximalItemsets.isEmpty) {
      return null;
    }

    final itemset = extractItemset(
      RepertoireLine(
        id: '_suggested',
        name: '_suggested',
        moves: moves,
        color: playAsWhite ? 'white' : 'black',
        startPosition: Chess.initial,
        fullPgn: '',
      ),
      playAsWhite,
    );
    return lineCoherence(itemset, coherenceResult.maximalItemsets);
  }

  BuildTreeNode? _walkTree(BuildTreeNode root, List<String> moves) {
    var current = root;
    for (final move in moves) {
      final child = current.children
          .where((c) => c.moveSan == move)
          .firstOrNull;
      if (child == null) return null;
      current = child;
    }
    return current;
  }

  List<SuggestedLine> _scoreAll(
    List<SuggestedLine> candidates,
    SuggestionWeights w,
  ) =>
      candidates.map((line) => line.withScore(_scoreLine(line, w))).toList()
        ..sort((a, b) => b.score.compareTo(a.score));

  /// Product of the factors each raised to its weight; every factor is a
  /// 0..1 quantity floored at 0.001 so a zero never wipes the others out.
  double _scoreLine(SuggestedLine line, SuggestionWeights w) {
    final impact = line.coverageGain / 100.0;
    final leafEvalCp = line.leafEvalCp;
    final eval = leafEvalCp != null ? winProbability(leafEvalCp) : 0.5;
    final ease = line.linePlayability ?? 0.5;
    final traps = line.trapCount > 0
        ? 0.7 + 0.3 * (line.trapCount / _trapSaturation).clamp(0.0, 1.0)
        : 0.5;

    var score =
        (pow(impact.clamp(0.001, 1.0), w.impactExp) *
                pow(eval.clamp(0.001, 1.0), w.evalExp) *
                pow(ease.clamp(0.001, 1.0), w.easeExp) *
                pow(traps.clamp(0.001, 1.0), w.trapExp))
            .toDouble();

    final coherenceBonus = line.coherenceBonus;
    if (coherenceBonus != null) {
      score *= pow(coherenceBonus.clamp(0.001, 1.0), w.coherenceExp);
    }

    return score;
  }

  List<SuggestedLine> _greedySelect(
    List<SuggestedLine> candidates,
    double targetCoverage,
    int? maxCount,
  ) {
    final selected = <SuggestedLine>[];
    var currentCoverage = coverage.coveragePercent;
    final used = <int>{};

    while (currentCoverage < targetCoverage &&
        (maxCount == null || selected.length < maxCount)) {
      double bestScore = 0;
      int bestIdx = -1;

      for (var i = 0; i < candidates.length; i++) {
        if (used.contains(i)) continue;
        final marginal = candidates[i].coverageGain;
        final adjusted = candidates[i].score * marginal;
        if (adjusted > bestScore) {
          bestScore = adjusted;
          bestIdx = i;
        }
      }

      if (bestIdx < 0) break;

      selected.add(candidates[bestIdx]);
      currentCoverage += candidates[bestIdx].coverageGain;
      used.add(bestIdx);
    }

    return selected;
  }
}
