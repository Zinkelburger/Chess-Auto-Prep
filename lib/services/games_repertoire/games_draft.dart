/// A reviewable draft repertoire derived from a player's own games.
///
/// Wraps the games [OpeningTree] plus its [RepertoireDiff] classification and
/// offers the two editing gestures the Draft tab needs:
///   • [prune]      – discard a whole subtree ("I don't play the French").
///   • [materialize]– turn the surviving lines into an editable [MoveTree]
///                    (and from there a PGN library entry).
///
/// Pure / synchronous / no I/O — fully unit-testable. Building the underlying
/// [OpeningTree] from PGN is done by the existing `UnifiedAnalysisBuilder`;
/// this class only operates on the result.
library;

import '../../models/move_tree.dart';
import '../../models/opening_tree.dart';
import 'repertoire_diff.dart';

/// Filters applied when materializing — discard noise before it reaches the
/// repertoire.
class DraftFilters {
  const DraftFilters({
    this.minGames = 1,
    this.maxDepth = 40,
    this.minMyWinRate,
  });

  /// Drop moves played in fewer than this many games.
  final int minGames;

  /// Stop materializing a line past this ply depth.
  final int maxDepth;

  /// When set, drop *my* moves whose win rate is below this (0..1). Opponent
  /// moves are never filtered on win rate (we still need an answer to them).
  final double? minMyWinRate;

  DraftFilters copyWith({int? minGames, int? maxDepth, double? minMyWinRate}) =>
      DraftFilters(
        minGames: minGames ?? this.minGames,
        maxDepth: maxDepth ?? this.maxDepth,
        minMyWinRate: minMyWinRate ?? this.minMyWinRate,
      );
}

class GamesDraft {
  GamesDraft({
    required this.tree,
    required this.isWhite,
  }) : diff = RepertoireDiff.compute(
          tree: tree,
          repertoire: MoveTree(),
          isWhite: isWhite,
        );

  /// Build a draft and classify it against an existing repertoire (review
  /// mode). Pass an empty [MoveTree] for the bootstrap case.
  GamesDraft.against({
    required this.tree,
    required this.isWhite,
    required MoveTree repertoire,
  }) : diff = RepertoireDiff.compute(
          tree: tree,
          repertoire: repertoire,
          isWhite: isWhite,
        );

  final OpeningTree tree;
  final bool isWhite;

  /// Classification of every node against the repertoire it was built against.
  RepertoireDiff diff;

  /// Discard the subtree rooted at [node] (and the node itself).
  /// No-op for the root. Returns true if something was removed.
  bool prune(OpeningTreeNode node) {
    final parent = node.parent;
    if (parent == null) return false;
    return parent.removeChild(node.move);
  }

  /// Re-run classification (e.g. after the repertoire changed underneath us).
  void reclassify(MoveTree repertoire) {
    diff = RepertoireDiff.compute(
      tree: tree,
      repertoire: repertoire,
      isWhite: isWhite,
    );
  }

  /// Build an editable [MoveTree] from the surviving lines.
  ///
  /// A branch is cut when a move fails [filters] (too few games, too deep, or
  /// — for my moves — below the win-rate floor).
  MoveTree materialize({DraftFilters filters = const DraftFilters()}) {
    final out = MoveTree();

    void walk(OpeningTreeNode node, TreePath parentPath, int depth) {
      if (depth >= filters.maxDepth) return;
      for (final child in node.sortedChildren) {
        if (child.gamesPlayed < filters.minGames) continue;

        final childDepth = depth + 1;
        final whiteMoved = childDepth.isOdd;
        final isMyMove = isWhite ? whiteMoved : !whiteMoved;
        if (isMyMove &&
            filters.minMyWinRate != null &&
            child.winRate < filters.minMyWinRate!) {
          continue;
        }

        final newPath = out.addMove(parentPath, child.move);
        if (newPath == null) continue; // illegal SAN — skip defensively
        walk(child, newPath, childDepth);
      }
    }

    walk(tree.root, TreePath.empty, 0);
    return out;
  }

  /// Materialize and serialize to PGN move text.
  String toPgnMoveText({DraftFilters filters = const DraftFilters()}) =>
      materialize(filters: filters).toPgnMoveText();
}
