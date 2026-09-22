/// Per-line quality, trap and coherence metrics for the lines list.
library;

import '../features/traps/services/trap_index_service.dart';
import '../chess_core/generation/build_tree_node.dart' show BuildTreeNode;
import '../models/repertoire_line.dart';
import '../chess_core/generation/trap_line_info.dart';
import 'coherence_service.dart';
import 'generation/tree_my_ease.dart';

/// Per-line quality/trap/coherence metrics.
class LineQualityInfo {
  final double? quality;
  final int? bottleneckPly;
  final double? bottleneckQuality;
  final bool bottleneckIsOurMove;
  final int trapCount;
  final int? bestTrapEvalDiff;
  final double? coherence;

  const LineQualityInfo({
    this.quality,
    this.bottleneckPly,
    this.bottleneckQuality,
    this.bottleneckIsOurMove = true,
    this.trapCount = 0,
    this.bestTrapEvalDiff,
    this.coherence,
  });

  /// Line playability from tree myEase (same as [quality]).
  double? get playability => quality;
}

/// Builds per-line metrics keyed by line id.
Map<String, LineQualityInfo> computeLineMetricsMap({
  required List<RepertoireLine> lines,
  required BuildTreeNode? treeRoot,
  required bool isWhiteRepertoire,
  required List<TrapLineInfo> traps,
  CoherenceResult? coherenceResult,
}) {
  final trapIndex = traps.isNotEmpty ? TrapIndexService(traps) : null;
  return {
    for (final line in lines)
      line.id: _metricsForLine(
        line,
        treeRoot: treeRoot,
        isWhiteRepertoire: isWhiteRepertoire,
        trapIndex: trapIndex,
        coherenceResult: coherenceResult,
      ),
  };
}

LineQualityInfo _metricsForLine(
  RepertoireLine line, {
  required BuildTreeNode? treeRoot,
  required bool isWhiteRepertoire,
  required TrapIndexService? trapIndex,
  required CoherenceResult? coherenceResult,
}) {
  final linePath = treeRoot == null
      ? const <BuildTreeNode>[]
      : walkTreeForLine(treeRoot, line.moves);
  final playability = linePath.isEmpty
      ? null
      : computeLinePlayability(linePath, isWhiteRepertoire);
  final trapMetrics = trapIndex?.metricsForLine(line.moves);
  final trapCount = trapMetrics?.count ?? 0;
  return LineQualityInfo(
    quality: playability?.playability,
    bottleneckPly: playability?.bottleneckPly,
    bottleneckQuality: playability?.bottleneckQuality,
    bottleneckIsOurMove: playability?.bottleneckIsOurMove ?? true,
    trapCount: trapCount,
    bestTrapEvalDiff: trapCount > 0 ? trapMetrics?.bestEvalDiff : null,
    coherence: coherenceResult?.lineCoherenceById[line.id],
  );
}

/// [computeLineMetricsMap] made incremental, on the same rule
/// `buildLineDisplayIndex` uses.
///
/// Pass the [previous] map and the [previousLines] it was built from: a
/// [RepertoireLine] is immutable and the controller replaces only the lines
/// that changed, so a line whose object is *identical* to the one it had
/// before keeps its metrics and every other line is re-derived.  An autosave
/// or a one-line append then costs one line, not the whole file.
///
/// Identity, not id: editing a line's moves rebuilds it as a new object under
/// the same id, so reusing on the id alone would leave that line's quality,
/// bottleneck ply and trap counts describing the moves it used to have.
///
/// The result covers exactly [lines], so entries for deleted lines are
/// dropped instead of accumulating for the life of the session.  Omit
/// [previous]/[previousLines] to derive everything.
Map<String, LineQualityInfo> buildLineMetricsIndex({
  required List<RepertoireLine> lines,
  required BuildTreeNode? treeRoot,
  required bool isWhiteRepertoire,
  required List<TrapLineInfo> traps,
  CoherenceResult? coherenceResult,
  Map<String, LineQualityInfo>? previous,
  List<RepertoireLine>? previousLines,
}) {
  Map<String, LineQualityInfo> derive(List<RepertoireLine> subset) =>
      subset.isEmpty
      ? const <String, LineQualityInfo>{}
      : computeLineMetricsMap(
          lines: subset,
          treeRoot: treeRoot,
          isWhiteRepertoire: isWhiteRepertoire,
          traps: traps,
          coherenceResult: coherenceResult,
        );

  if (previous == null || previousLines == null) return derive(lines);

  final before = <String, RepertoireLine>{
    for (final line in previousLines) line.id: line,
  };
  final computed = derive([
    for (final line in lines)
      if (!previous.containsKey(line.id) || !identical(before[line.id], line))
        line,
  ]);

  return {
    for (final line in lines)
      line.id: ?(computed[line.id] ?? previous[line.id]),
  };
}

/// The nodes of [root]'s tree along [moves], root first, stopping at the
/// first move the tree does not hold.
List<BuildTreeNode> walkTreeForLine(BuildTreeNode root, List<String> moves) {
  final path = <BuildTreeNode>[root];
  var current = root;
  for (final move in moves) {
    final child = _childBySan(current, move);
    if (child == null) break;
    current = child;
    path.add(current);
  }
  return path;
}

BuildTreeNode? _childBySan(BuildTreeNode node, String san) {
  for (final child in node.children) {
    if (child.moveSan == san) return child;
  }
  return null;
}
