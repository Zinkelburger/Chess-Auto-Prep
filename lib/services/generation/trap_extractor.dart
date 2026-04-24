/// Extracts trap lines from a [BuildTree].
///
/// Mirrors the C `find_trap_lines` / `find_detailed_traps_callback` logic:
/// walks every opponent-move node with ≥ 2 children, computes trap score and
/// trick surplus, collects candidates above thresholds, and sorts by trick
/// surplus descending.
library;

import 'dart:convert';
import 'dart:io';

import '../../models/build_tree_node.dart';
import '../../models/trap_line_info.dart';
import '../../utils/ease_utils.dart' show winProbability;

class TrapExtractor {
  final bool playAsWhite;
  final int maxTraps;

  /// Minimum trap score to consider (matches C default 0.05).
  final double minTrapScore;

  /// Minimum trick surplus to include (matches C default 0.005).
  final double minTrickSurplus;

  TrapExtractor({
    required this.playAsWhite,
    this.maxTraps = 200,
    this.minTrapScore = 0.05,
    this.minTrickSurplus = 0.005,
  });

  /// Walk the tree and return trap lines sorted by trick surplus descending.
  List<TrapLineInfo> extract(BuildTree tree) {
    final candidates = <_TrapCandidate>[];
    _collectTraps(tree.root, candidates);

    candidates.sort((a, b) => b.trickSurplus.compareTo(a.trickSurplus));

    final limit = candidates.length > maxTraps ? maxTraps : candidates.length;
    final results = <TrapLineInfo>[];

    for (int i = 0; i < limit; i++) {
      final c = candidates[i];
      final moves = c.node.getLineSan();

      results.add(TrapLineInfo(
        movesSan: moves,
        trapScore: c.trapScore,
        popularProb: c.popularProb,
        popularMove: c.popularMove,
        bestMove: c.bestMove,
        popularEvalCp: c.popularEvalUs,
        bestEvalCp: c.bestEvalUs,
        evalDiffCp: c.evalDiffUs,
        cumulativeProb: c.node.cumulativeProbability,
        trickSurplus: c.trickSurplus,
        expectimaxValue: c.node.expectimaxValue,
        wpEval: c.wpEval,
      ));
    }

    return results;
  }

  void _collectTraps(BuildTreeNode node, List<_TrapCandidate> candidates) {
    for (final child in node.children) {
      _collectTraps(child, candidates);
    }

    // Only opponent-move nodes with at least 2 children
    final isOpponentMove = playAsWhite
        ? !node.isWhiteToMove
        : node.isWhiteToMove;
    if (!isOpponentMove) return;
    if (node.children.length < 2) return;

    BuildTreeNode? mostPopular;
    BuildTreeNode? bestMoveNode;
    double highestProb = 0.0;
    int bestEval = -100000;

    for (final child in node.children) {
      if (child.moveProbability > highestProb) {
        highestProb = child.moveProbability;
        mostPopular = child;
      }
      if (child.hasEngineEval) {
        final evalForMover = -child.engineEvalCp!;
        if (evalForMover > bestEval) {
          bestEval = evalForMover;
          bestMoveNode = child;
        }
      }
    }

    if (mostPopular == null || bestMoveNode == null) return;
    if (mostPopular == bestMoveNode) return;

    if (!mostPopular.hasEngineEval) return;
    final popularEval = -mostPopular.engineEvalCp!;

    final evalDiff = bestEval - popularEval;
    if (evalDiff <= 0) return;

    double trap = evalDiff / 200.0;
    if (trap > 1.0) trap = 1.0;
    trap *= highestProb;
    if (trap <= minTrapScore) return;

    // Trick surplus: how much better we do practically vs raw eval.
    if (!node.hasExpectimax) return;
    final evalUs = node.isWhiteToMove == playAsWhite
        ? (node.engineEvalCp ?? 0)
        : -(node.engineEvalCp ?? 0);
    final wpEval = winProbability(evalUs);
    final surplus = node.expectimaxValue - wpEval;
    if (surplus <= minTrickSurplus) return;

    // Convert evals to "our" perspective (at opponent-move nodes,
    // mover is opponent, so our eval = -mover's eval).
    final popularEvalUs = -popularEval;
    final bestEvalUs = -bestEval;
    final evalDiffUs = popularEvalUs - bestEvalUs;

    candidates.add(_TrapCandidate(
      node: node,
      trapScore: trap,
      popularProb: highestProb,
      popularMove: mostPopular.moveSan,
      bestMove: bestMoveNode.moveSan,
      popularEvalUs: popularEvalUs,
      bestEvalUs: bestEvalUs,
      evalDiffUs: evalDiffUs,
      trickSurplus: surplus,
      wpEval: wpEval,
    ));
  }

  /// Save trap lines to a JSON file alongside the repertoire.
  static Future<void> saveToFile(
    List<TrapLineInfo> traps,
    String repertoireFilePath,
  ) async {
    final base = repertoireFilePath.replaceAll(RegExp(r'\.pgn$'), '');
    final trapPath = '${base}_traps.json';

    final data = {
      'generated_at': DateTime.now().toIso8601String(),
      'count': traps.length,
      'traps': traps.map((t) => t.toJson()).toList(),
    };

    await File(trapPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
    );
  }

  /// Load trap lines from the JSON file for a given repertoire.
  /// Returns null if no file exists or parse fails.
  static Future<List<TrapLineInfo>?> loadFromFile(
    String repertoireFilePath,
  ) async {
    final base = repertoireFilePath.replaceAll(RegExp(r'\.pgn$'), '');
    final trapPath = '${base}_traps.json';

    final file = File(trapPath);
    if (!await file.exists()) return null;

    try {
      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final traps = (data['traps'] as List)
          .map((j) => TrapLineInfo.fromJson(j as Map<String, dynamic>))
          .toList();
      return traps;
    } catch (_) {
      return null;
    }
  }
}

class _TrapCandidate {
  final BuildTreeNode node;
  final double trapScore;
  final double popularProb;
  final String popularMove;
  final String bestMove;
  final int popularEvalUs;
  final int bestEvalUs;
  final int evalDiffUs;
  final double trickSurplus;
  final double wpEval;

  _TrapCandidate({
    required this.node,
    required this.trapScore,
    required this.popularProb,
    required this.popularMove,
    required this.bestMove,
    required this.popularEvalUs,
    required this.bestEvalUs,
    required this.evalDiffUs,
    required this.trickSurplus,
    required this.wpEval,
  });
}
