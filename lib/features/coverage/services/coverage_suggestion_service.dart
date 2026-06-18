/// Generates prioritized line suggestions to reach a target coverage %.
///
/// Pipeline: gaps → resolve → score → greedy set-cover selection.
library;

import 'dart:math' show pow;

import 'package:dartchess/dartchess.dart';

import '../../../models/build_tree_node.dart';
import '../../../models/repertoire_line.dart';
import '../../../services/coherence_service.dart';
import '../../../utils/ease_utils.dart' show winProbability;
import 'coverage_service.dart';
import '../../../services/generation/fen_map.dart';

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
  final GapCandidate gap;
  final List<String> fullMoves;
  final List<String> newMoves;
  final double coverageGain;
  final double score;
  final String source;
  final int? leafEvalCp;
  final double? linePlayability;
  final int trapCount;
  final double? coherenceBonus;

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
}

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

  static const maxCoverage =
      SuggestionWeights(impactExp: 1.0, evalExp: 0, easeExp: 0);
  static const balanced =
      SuggestionWeights(impactExp: 0.5, evalExp: 0.3, easeExp: 0.2);
  static const playable =
      SuggestionWeights(impactExp: 0.3, evalExp: 0.2, easeExp: 0.5);
  static const trappy = SuggestionWeights(
      impactExp: 0.4, evalExp: 0.2, easeExp: 0.1, trapExp: 0.3);
}

class CoverageSuggestionService {
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

  List<SuggestedLine> generateSuggestions({
    required double targetCoverage,
    required bool playAsWhite,
    SuggestionWeights weights = const SuggestionWeights(),
    int maxSuggestions = 10,
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
      gaps.add(GapCandidate(
        pathToGap: [...um.parentMoves, um.move],
        fen: '',
        type: GapType.unaccounted,
        gameCount: gameCount,
        coverageImpact:
            coverage.rootGameCount > 0 ? gameCount / coverage.rootGameCount : 0,
        opponentMove: um.move,
      ));
    }

    for (final leaf in coverage.tooShallowLeaves) {
      gaps.add(GapCandidate(
        pathToGap: leaf.moves,
        fen: leaf.fen,
        type: GapType.tooShallow,
        gameCount: leaf.gameCount,
        coverageImpact: coverage.rootGameCount > 0
            ? leaf.gameCount / coverage.rootGameCount
            : 0,
      ));
    }

    gaps.sort((a, b) => b.gameCount.compareTo(a.gameCount));
    return gaps;
  }

  List<SuggestedLine> _resolveLines(List<GapCandidate> gaps, bool playAsWhite) {
    final results = <SuggestedLine>[];
    final maxGaps = gaps.length > 50 ? 50 : gaps.length;

    for (var i = 0; i < maxGaps; i++) {
      final gap = gaps[i];
      final treeLine = _findTreePath(gap, playAsWhite);
      if (treeLine != null) {
        results.add(treeLine);
      }
    }

    return results;
  }

  SuggestedLine? _findTreePath(GapCandidate gap, bool playAsWhite) {
    if (tree == null) return null;

    BuildTreeNode? node;
    if (gap.fen.isNotEmpty && fenMap != null) {
      node = fenMap!.getCanonical(gap.fen);
    }
    node ??= _walkTree(tree!.root, gap.pathToGap);
    if (node == null) return null;

    final path = <String>[...gap.pathToGap];
    var current = node;
    int trapCount = 0;

    for (var depth = 0; depth < 12 && current.children.isNotEmpty; depth++) {
      final repertoireChild =
          current.children.where((c) => c.isRepertoireMove).toList();
      final next = repertoireChild.isNotEmpty
          ? repertoireChild.first
          : current.children
              .reduce((a, b) => a.expectimaxValue >= b.expectimaxValue ? a : b);

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
      final child = current.children.where((c) => c.moveSan == move).toList();
      if (child.isEmpty) return null;
      current = child.first;
    }
    return current;
  }

  List<SuggestedLine> _scoreAll(
      List<SuggestedLine> candidates, SuggestionWeights w) {
    return candidates.map((line) {
      final score = _scoreLine(line, w);
      return SuggestedLine(
        gap: line.gap,
        fullMoves: line.fullMoves,
        newMoves: line.newMoves,
        coverageGain: line.coverageGain,
        score: score,
        source: line.source,
        leafEvalCp: line.leafEvalCp,
        linePlayability: line.linePlayability,
        trapCount: line.trapCount,
        coherenceBonus: line.coherenceBonus,
      );
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));
  }

  double _scoreLine(SuggestedLine line, SuggestionWeights w) {
    final impact = line.coverageGain / 100.0;
    final eval =
        line.leafEvalCp != null ? winProbability(line.leafEvalCp!) : 0.5;
    final ease = line.linePlayability ?? 0.5;
    final traps = line.trapCount > 0
        ? 0.7 + 0.3 * (line.trapCount / 5).clamp(0.0, 1.0)
        : 0.5;

    var score = (pow(impact.clamp(0.001, 1.0), w.impactExp) *
            pow(eval.clamp(0.001, 1.0), w.evalExp) *
            pow(ease.clamp(0.001, 1.0), w.easeExp) *
            pow(traps.clamp(0.001, 1.0), w.trapExp))
        .toDouble();

    if (line.coherenceBonus != null) {
      score *= pow(line.coherenceBonus!.clamp(0.001, 1.0), w.coherenceExp);
    }

    return score;
  }

  List<SuggestedLine> _greedySelect(
    List<SuggestedLine> candidates,
    double targetCoverage,
    int maxCount,
  ) {
    final selected = <SuggestedLine>[];
    var currentCoverage = coverage.coveragePercent;
    final used = <int>{};

    while (currentCoverage < targetCoverage && selected.length < maxCount) {
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
