/// Extracts trap lines from a [BuildTree].
///
/// Mirrors the C `find_trap_lines` / `find_detailed_traps_callback` logic:
/// walks every opponent-move node with ≥ 2 children, computes trap score and
/// trick surplus, collects candidates above thresholds, and sorts by trick
/// surplus descending.
library;

import '../../chess_core/generation/build_tree_node.dart';
import '../../chess_core/generation/trap_line_info.dart';
import '../../chess_core/generation/trap_reply.dart';
import '../../utils/ease_utils.dart' show winProbability;
import '../../chess_core/position/eval_canonicalize.dart';
import 'trap_score.dart';

class TrapExtractor {
  final bool playAsWhite;

  /// Minimum trap score to consider (matches C default 0.05).
  final double minTrapScore;

  /// Minimum trick surplus to include (matches C default 0.005).
  final double minTrickSurplus;

  /// Findability bar (`pRefForElo(maiaElo)`) discounting traps whose
  /// punishing reply is a move a human rarely finds; null disables.
  final double? findabilityPRef;

  TrapExtractor({
    required this.playAsWhite,
    this.minTrapScore = 0.05,
    this.minTrickSurplus = 0.005,
    this.findabilityPRef,
  });

  /// Walk the tree and return trap lines sorted by trick surplus descending.
  ///
  /// Deduplicates by FEN so transpositions don't produce repeated entries.
  List<TrapLineInfo> extract(BuildTree tree) {
    final candidates = <_TrapCandidate>[];
    _collectTraps(tree.root, candidates);

    candidates.sort((a, b) => b.trickSurplus.compareTo(a.trickSurplus));

    final seenFens = <String>{};
    final results = <TrapLineInfo>[];

    for (final c in candidates) {
      if (!seenFens.add(canonicalizeFen4(c.fen))) continue;
      final moves = c.node.getLineSan();

      results.add(
        TrapLineInfo(
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
          fen: c.fen,
          openingName: c.openingName,
          positionEvalCp: c.positionEvalCp,
          allReplies: c.allReplies,
          refutationMove: c.refutationMove,
          refutationEvalCp: c.refutationEvalCp,
        ),
      );
    }

    return results;
  }

  /// Whether the build's own trap pass already scored [node] below the bar.
  ///
  /// Phase 2 runs this same analysis on every opponent node and stores the
  /// result in [BuildTreeNode.trapScore] (-1 when it never ran).  Almost every
  /// node fails [minTrapScore], so re-running the analysis here just to
  /// reject it again was the bulk of the extractor's work on every publish.
  /// The findability discount only ever lowers a score, so a stored score
  /// under the bar is conclusive whenever this extractor discounts too;
  /// without a discount the undiscounted score could still clear it, and the
  /// analysis runs.
  bool _rejectedByStoredScore(BuildTreeNode node) =>
      findabilityPRef != null &&
      node.trapScore >= 0.0 &&
      node.trapScore <= minTrapScore;

  void _collectTraps(BuildTreeNode node, List<_TrapCandidate> candidates) {
    for (final child in node.children) {
      _collectTraps(child, candidates);
    }

    // Only opponent-move nodes with at least 2 children
    // (analyzeTrapScore returns null for fewer than 2 children).
    if (node.isWhiteToMove == playAsWhite) return;
    if (_rejectedByStoredScore(node)) return;

    final analysis = analyzeTrapScore(node, findabilityPRef: findabilityPRef);
    if (analysis == null || analysis.popularIsBest) return;

    final mostPopular = analysis.mostPopular;
    final bestMoveNode = analysis.bestMove;
    final highestProb = analysis.highestProb;
    final bestEval = analysis.bestEvalForMover;
    final popularEval = analysis.popularEvalForMover;

    final evalDiff = bestEval - popularEval;
    if (evalDiff <= 0) return;

    final trap = analysis.trapScore;
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

    // Our reply after the blunder: the repertoire move when selection has
    // run, else the best-scoring one — the analysis already picked it.
    final refutation = analysis.refutation;

    candidates.add(
      _TrapCandidate(
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
        fen: node.fen,
        openingName: node.openingName,
        positionEvalCp: evalUs,
        allReplies: _buildAllReplies(node, bestEvalUs),
        refutationMove: refutation?.moveSan,
        refutationEvalCp: refutation?.evalForUs(playAsWhite),
      ),
    );
  }

  /// Builds classified opponent replies at a trap position, sorted by probability.
  List<TrapReply> _buildAllReplies(BuildTreeNode node, int bestEvalUs) {
    final replies = <TrapReply>[];
    for (final child in node.children) {
      final evalAfterCp = child.hasEngineEval
          ? child.evalForUs(playAsWhite)
          : 0;
      final diffFromBest = evalAfterCp - bestEvalUs;
      replies.add(
        TrapReply(
          san: child.moveSan,
          probability: child.moveProbability,
          evalAfterCp: evalAfterCp,
          classification: TrapReply.classify(diffFromBest),
        ),
      );
    }
    replies.sort((a, b) => b.probability.compareTo(a.probability));
    return replies;
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
  final String fen;
  final String? openingName;
  final int positionEvalCp;
  final List<TrapReply> allReplies;
  final String? refutationMove;
  final int? refutationEvalCp;

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
    required this.fen,
    this.openingName,
    required this.positionEvalCp,
    required this.allReplies,
    this.refutationMove,
    this.refutationEvalCp,
  });
}

/// Keeps only the lines that run through one of [traps].
///
/// A trap is recorded at the position *before* the opponent's tempting
/// mistake, so a line "contains" the trap when the trap's move sequence is a
/// prefix of the line.  Used by `trapsOnly` export: the tree is built and
/// selected exactly as usual, then everything that teaches no trap is
/// dropped, turning the PGN into a trap collection instead of a repertoire.
///
/// Returns an empty list when [traps] is empty — no traps found means
/// nothing to export, which the caller reports rather than silently
/// falling back to the full repertoire.
List<T> keepLinesThroughTraps<T>(
  List<T> lines,
  List<TrapLineInfo> traps,
  List<String> Function(T line) movesOf,
) {
  if (traps.isEmpty) return const [];
  final prefixes = <String>{
    for (final t in traps)
      if (t.movesSan.isNotEmpty) t.movesSan.join(' '),
  };
  if (prefixes.isEmpty) return const [];

  return lines.where((line) {
    final moves = movesOf(line);
    // Walk the line's own prefixes: cheaper than substring-matching every
    // trap against every line, and exact on move boundaries.
    final buffer = StringBuffer();
    for (var i = 0; i < moves.length; i++) {
      if (i > 0) buffer.write(' ');
      buffer.write(moves[i]);
      if (prefixes.contains(buffer.toString())) return true;
    }
    return false;
  }).toList();
}
