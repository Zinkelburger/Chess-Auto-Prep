import 'package:flutter/material.dart';

import '../../models/opening_tree.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/fen_utils.dart';

/// Coverage classification for an opening-tree move row.
enum CoverageStatus { covered, tooShallow, tooDeep, unaccounted }

/// Resolves coverage status for a child move (a transposition [group]) based
/// on [coverageResult] and [tree].
CoverageStatus? resolveCoverageStatus({
  required PositionGroup group,
  required OpeningTree tree,
  CoverageResult? coverageResult,
}) {
  if (coverageResult == null) return null;

  // FEN-based classification is identical for every node in the group.
  var status = _coverageStatusForNode(group.primaryNode, coverageResult);
  // The unaccounted check is path-dependent, so any path may trigger it.
  if (status == null &&
      group.nodes.any((n) => _hasUnaccountedFrom(n, tree, coverageResult))) {
    status = CoverageStatus.unaccounted;
  }
  return status;
}

CoverageStatus? _coverageStatusForNode(
  OpeningTreeNode node,
  CoverageResult result,
) {
  final normalized = normalizeFen(node.fen);

  for (final leaf in result.tooShallowLeaves) {
    if (_leafMatchesFen(leaf, normalized)) {
      return CoverageStatus.tooShallow;
    }
  }
  for (final leaf in result.tooDeepLeaves) {
    if (_leafMatchesFen(leaf, normalized)) {
      return CoverageStatus.tooDeep;
    }
  }

  for (final um in result.unaccountedMoves) {
    if (_unaccountedAtFen(um, normalized)) {
      return CoverageStatus.unaccounted;
    }
  }

  for (final leaf in result.coveredLeaves) {
    if (_leafMatchesFen(leaf, normalized)) {
      return CoverageStatus.covered;
    }
  }

  return null;
}

bool _leafMatchesFen(LeafNode leaf, String normalizedFen) {
  return normalizeFen(leaf.fen) == normalizedFen;
}

bool _unaccountedAtFen(UnaccountedMove um, String normalizedFen) {
  // Rebuild the FEN for parentMoves + move (the destination position)
  // But that's expensive. Instead check if the node's FEN is the parent position.
  // We can't easily rebuild here, so we use a simpler heuristic:
  // match via the tree's fen-to-node index.
  return false; // Handled at the parent level below.
}

/// Check if there are unaccounted moves FROM this position (opponent responses
/// that our repertoire doesn't cover).
bool _hasUnaccountedFrom(
  OpeningTreeNode node,
  OpeningTree tree,
  CoverageResult result,
) {
  final normalized = normalizeFen(node.fen);

  for (final um in result.unaccountedMoves) {
    final parentNodes = tree.fenToNodes[normalized];
    if (parentNodes != null && parentNodes.isNotEmpty) {
      final repertoireMoves = node.children.keys.toSet();
      if (!repertoireMoves.contains(um.move)) {
        final nodePath = node.getMovePath();
        if (_pathMatchesUnaccounted(nodePath, um.parentMoves)) {
          return true;
        }
      }
    }
  }
  return false;
}

bool _pathMatchesUnaccounted(List<String> nodePath, List<String> parentMoves) {
  if (nodePath.length != parentMoves.length) return false;
  for (int i = 0; i < nodePath.length; i++) {
    if (nodePath[i] != parentMoves[i]) return false;
  }
  return true;
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
