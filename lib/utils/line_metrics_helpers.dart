import '../models/build_tree_node.dart' show BuildTreeNode;
import '../models/repertoire_line.dart';
import '../models/trap_line_info.dart';
import '../services/coherence_service.dart';
import '../services/generation/tree_my_ease.dart';
import '../services/trap_index_service.dart';

/// Per-line quality/trap/coherence metrics.
class LineQualityInfo {
  final double? quality;
  final int? bottleneckPly;
  final double? bottleneckQuality;
  final int trapCount;
  final double? coherence;

  const LineQualityInfo({
    this.quality,
    this.bottleneckPly,
    this.bottleneckQuality,
    this.trapCount = 0,
    this.coherence,
  });
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
    double? coherence;

    if (treeRoot != null) {
      final linePath = walkTreeForLine(treeRoot, line.moves);
      if (linePath.isNotEmpty) {
        final lp = computeLinePlayability(linePath, isWhiteRepertoire);
        quality = lp.playability;
        bottleneckPly = lp.bottleneckPly;
        bottleneckQuality = lp.bottleneckQuality;
      }
    }

    if (trapIndex != null) {
      trapCount = trapIndex.trapsInLine(line.moves).length;
    }

    if (coherenceResult != null) {
      coherence = coherenceResult.lineCoherenceById[line.id];
    }

    map[line.id] = LineQualityInfo(
      quality: quality,
      bottleneckPly: bottleneckPly,
      bottleneckQuality: bottleneckQuality,
      trapCount: trapCount,
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
    final child =
        current.children.where((c) => c.moveSan == move).toList();
    if (child.isEmpty) break;
    current = child.first;
    path.add(current);
  }
  return path;
}
