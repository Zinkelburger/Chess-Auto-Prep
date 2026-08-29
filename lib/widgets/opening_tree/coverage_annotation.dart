import 'package:flutter/material.dart';

import '../../models/opening_tree.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/fen_utils.dart';

/// Coverage classification for an opening-tree move row.
enum CoverageStatus { covered, tooShallow, tooDeep, unaccounted }

/// Coverage lookups for one [CoverageResult], built once and reused for
/// every row of every rebuild.
///
/// The result lists leaves and unaccounted moves as flat lists; classifying
/// a row by scanning them (and normalising every leaf's FEN on the way) cost
/// O(rows × leaves) per rebuild.  Indexed by normalised FEN and by parent
/// path, each row is two map lookups.
class CoverageIndex {
  CoverageIndex(this.result)
    : _leafStatus = _indexLeaves(result),
      _unaccountedByPath = _indexUnaccounted(result);

  final CoverageResult result;

  /// Normalised FEN → status of the leaf that sits on it.  Shallow and deep
  /// leaves win over covered ones, in the order the row logic always used.
  final Map<String, CoverageStatus> _leafStatus;

  /// `parentMoves.join(' ')` → the opponent moves the repertoire leaves
  /// unanswered from that path.
  final Map<String, Set<String>> _unaccountedByPath;

  static Map<String, CoverageStatus> _indexLeaves(CoverageResult result) {
    final out = <String, CoverageStatus>{};
    // Insert lowest priority first so later puts override.
    for (final leaf in result.coveredLeaves) {
      out[normalizeFen(leaf.fen)] = CoverageStatus.covered;
    }
    for (final leaf in result.tooDeepLeaves) {
      out[normalizeFen(leaf.fen)] = CoverageStatus.tooDeep;
    }
    for (final leaf in result.tooShallowLeaves) {
      out[normalizeFen(leaf.fen)] = CoverageStatus.tooShallow;
    }
    return out;
  }

  static Map<String, Set<String>> _indexUnaccounted(CoverageResult result) {
    final out = <String, Set<String>>{};
    for (final um in result.unaccountedMoves) {
      (out[um.parentMoves.join(' ')] ??= {}).add(um.move);
    }
    return out;
  }

  /// Coverage status for a child move (a transposition [group]).
  CoverageStatus? statusOf(PositionGroup group) {
    // FEN-based classification is identical for every node in the group.
    final byLeaf = _leafStatus[normalizeFen(group.primaryNode.fen)];
    if (byLeaf != null) return byLeaf;
    // The unaccounted check is path-dependent, so any path may trigger it.
    if (_unaccountedByPath.isNotEmpty && group.nodes.any(_hasUnaccountedFrom)) {
      return CoverageStatus.unaccounted;
    }
    return null;
  }

  /// Whether the repertoire leaves an opponent reply from [node]'s path
  /// unanswered (the reply is listed as unaccounted from exactly this path
  /// and is not among the node's children).
  bool _hasUnaccountedFrom(OpeningTreeNode node) {
    final moves = _unaccountedByPath[node.getMovePath().join(' ')];
    if (moves == null) return false;
    for (final move in moves) {
      if (!node.children.containsKey(move)) return true;
    }
    return false;
  }
}

/// Resolves coverage status for a child move (a transposition [group]) based
/// on [coverageResult].  One-off convenience over [CoverageIndex]; a widget
/// that classifies many rows should build the index once per result.
CoverageStatus? resolveCoverageStatus({
  required PositionGroup group,
  required OpeningTree tree,
  CoverageResult? coverageResult,
}) {
  if (coverageResult == null) return null;
  return CoverageIndex(coverageResult).statusOf(group);
}

/// Small colored dot indicating repertoire coverage for a move row.
class CoverageIndicator extends StatelessWidget {
  final CoverageStatus status;

  const CoverageIndicator({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (status) {
      case CoverageStatus.covered:
        color = AppColors.coverageCovered;
      case CoverageStatus.tooShallow:
        color = AppColors.coverageShallow;
      case CoverageStatus.tooDeep:
        color = AppColors.coverageDeep;
      case CoverageStatus.unaccounted:
        color = AppColors.coverageUnaccounted;
    }

    return Container(
      width: 8,
      height: 8,
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
