import '../models/build_tree_node.dart' show BuildTreeNode;
import '../models/repertoire_line.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
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
  final map = <String, LineQualityInfo>{};

  for (final line in lines) {
    double? quality;
    int? bottleneckPly;
    double? bottleneckQuality;
    var trapCount = 0;
    int? bestTrapEvalDiff;
    double? coherence;

    bool bottleneckIsOurMove = true;

    if (treeRoot != null) {
      final linePath = walkTreeForLine(treeRoot, line.moves);
      if (linePath.isNotEmpty) {
        final lp = computeLinePlayability(linePath, isWhiteRepertoire);
        quality = lp.playability;
        bottleneckPly = lp.bottleneckPly;
        bottleneckQuality = lp.bottleneckQuality;
        bottleneckIsOurMove = lp.bottleneckIsOurMove;
      }
    }

    if (trapIndex != null) {
      final trapMetrics = trapIndex.metricsForLine(line.moves);
      trapCount = trapMetrics.count;
      if (trapMetrics.count > 0) {
        bestTrapEvalDiff = trapMetrics.bestEvalDiff;
      }
    }

    if (coherenceResult != null) {
      coherence = coherenceResult.lineCoherenceById[line.id];
    }

    map[line.id] = LineQualityInfo(
      quality: quality,
      bottleneckPly: bottleneckPly,
      bottleneckQuality: bottleneckQuality,
      bottleneckIsOurMove: bottleneckIsOurMove,
      trapCount: trapCount,
      bestTrapEvalDiff: bestTrapEvalDiff,
      coherence: coherence,
    );
  }

  return map;
}

List<BuildTreeNode> walkTreeForLine(
  BuildTreeNode root,
  List<String> moves,
) {
  final path = <BuildTreeNode>[root];
  var current = root;
  for (final move in moves) {
    final child = current.children.where((c) => c.moveSan == move).toList();
    if (child.isEmpty) break;
    current = child.first;
    path.add(current);
  }
  return path;
}
