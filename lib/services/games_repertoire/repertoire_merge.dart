/// Merges a draft [MoveTree] into a target repertoire [MoveTree].
///
/// Merge is a *union*: identical prefixes collapse silently; a divergent move
/// lands as a new sibling. Where the divergence is at one of *my* decision
/// points (the side that owns the repertoire is to move and now has more than
/// one candidate), we flag a [MergeConflict] so the UI can surface it — "BOOM,
/// resolve this" — and the user picks mainline vs sideline with the existing
/// `MoveTree.promoteVariation` gesture.
///
/// Pure / synchronous — fully unit-testable. Reuses `MoveTree.addMove`.
library;

import '../../models/move_tree.dart';

/// A spot where the draft introduced a second candidate move at one of my
/// decision points — needs a mainline/sideline choice.
class MergeConflict {
  const MergeConflict({
    required this.parentPath,
    required this.draftPath,
    required this.draftSan,
    required this.existingSans,
  });

  /// Path to the position where the choice has to be made.
  final TreePath parentPath;

  /// Path to the move the draft just added (a sibling among [existingSans]).
  final TreePath draftPath;

  /// The move the draft contributed.
  final String draftSan;

  /// The candidate move(s) that were already in the repertoire here.
  final List<String> existingSans;
}

/// Result of a merge: how much changed and what needs resolving.
class MergeResult {
  MergeResult({
    required this.addedMoves,
    required this.conflicts,
  });

  /// Number of moves the draft added that weren't already present.
  final int addedMoves;

  /// Decision points that gained a competing move.
  final List<MergeConflict> conflicts;

  bool get hasConflicts => conflicts.isNotEmpty;
}

class RepertoireMerge {
  /// Fold [draft] into [target] in place. [isWhite] selects whose decision
  /// points count as conflicts.
  static MergeResult merge({
    required MoveTree target,
    required MoveTree draft,
    required bool isWhite,
  }) {
    final conflicts = <MergeConflict>[];
    var added = 0;

    void walk(List<dynamic> draftSiblings, TreePath targetParentPath) {
      for (final draftNode in draftSiblings.cast<MoveNode>()) {
        final existing = _childrenSansAt(target, targetParentPath);
        final alreadyPresent = existing.contains(draftNode.san);

        final newPath = target.addMove(targetParentPath, draftNode.san);
        if (newPath == null) continue; // illegal — defensive

        if (!alreadyPresent) {
          added++;
          // Divergence: target already had a different move(s) here.
          if (existing.isNotEmpty) {
            final fen = target.fenAt(targetParentPath);
            if (_sideToMoveIsMine(fen, isWhite)) {
              conflicts.add(MergeConflict(
                parentPath: targetParentPath,
                draftPath: newPath,
                draftSan: draftNode.san,
                existingSans: existing,
              ));
            }
          }
        }

        walk(draftNode.children, newPath);
      }
    }

    walk(draft.roots, TreePath.empty);
    return MergeResult(addedMoves: added, conflicts: conflicts);
  }

  static List<String> _childrenSansAt(MoveTree tree, TreePath path) {
    final siblings = path.isEmpty ? tree.roots : tree.nodeAt(path)?.children;
    if (siblings == null) return const [];
    return siblings.map((n) => n.san).toList();
  }

  static bool _sideToMoveIsMine(String fen, bool isWhite) {
    final parts = fen.split(' ');
    final whiteToMove = parts.length < 2 || parts[1] == 'w';
    return isWhite == whiteToMove;
  }
}
