/// Classifies the moves in a games [OpeningTree] against a repertoire
/// [MoveTree], from the perspective of one side.
///
/// This is the engine shared by both halves of the games-driven-repertoire
/// loop (see `docs/GAMES_DRIVEN_REPERTOIRE.md`):
///   • empty repertoire  → every move is a deviation = the *bootstrap* draft.
///   • populated rep.     → only off-book moves surface = the *review*.
///
/// Pure / synchronous / no I/O — fully unit-testable.
library;

import '../../models/move_tree.dart';
import '../../models/opening_tree.dart';

/// Where a single games-tree move stands relative to the repertoire.
enum DraftMoveStatus {
  /// The move (and its whole prefix) is already in the repertoire.
  inRepertoire,

  /// Prefix is covered, but *my* side played a move not in the repertoire.
  /// = drifted from prep, or a new idea worth adding.
  myDeviation,

  /// Prefix is covered, but the *opponent* played a move not in the
  /// repertoire. = a gap with no prepared answer.
  opponentDeviation,

  /// We are already past the first deviation on this line — continuation
  /// moves that live entirely outside the book.
  beyondBook,
}

/// Classification of one [OpeningTreeNode].
class DraftMoveInfo {
  const DraftMoveInfo({
    required this.status,
    required this.isMyMove,
    required this.depth,
  });

  final DraftMoveStatus status;

  /// True when this move was made by the side that owns the repertoire.
  final bool isMyMove;

  /// Ply depth from the root (1 = first move of the game).
  final int depth;

  bool get isDeviation =>
      status == DraftMoveStatus.myDeviation ||
      status == DraftMoveStatus.opponentDeviation;
}

/// Annotates every node of [tree] against [repertoire].
///
/// [isWhite] selects whose repertoire we are comparing to: for a White
/// repertoire, White's moves are "mine" and Black's are the opponent's.
class RepertoireDiff {
  RepertoireDiff._(this.annotations);

  /// Per-node classification. Keyed by node identity (the [OpeningTreeNode]
  /// instances of the tree passed to [compute]).
  final Map<OpeningTreeNode, DraftMoveInfo> annotations;

  DraftMoveInfo? operator [](OpeningTreeNode node) => annotations[node];

  /// Convenience tallies for headline UI.
  int get inRepertoireCount => _count(DraftMoveStatus.inRepertoire);
  int get myDeviationCount => _count(DraftMoveStatus.myDeviation);
  int get opponentDeviationCount => _count(DraftMoveStatus.opponentDeviation);
  int get beyondBookCount => _count(DraftMoveStatus.beyondBook);

  int _count(DraftMoveStatus s) =>
      annotations.values.where((a) => a.status == s).length;

  static RepertoireDiff compute({
    required OpeningTree tree,
    required MoveTree repertoire,
    required bool isWhite,
  }) {
    final out = <OpeningTreeNode, DraftMoveInfo>{};

    void walk(OpeningTreeNode node, List<String> pathSans, bool parentCovered) {
      for (final child in node.sortedChildren) {
        final sans = [...pathSans, child.move];
        final depth = sans.length;
        // depth 1 = first move = White. White moves sit at odd depths.
        final whiteMoved = depth.isOdd;
        final isMyMove = isWhite ? whiteMoved : !whiteMoved;

        final covered = parentCovered && _repertoireHasPath(repertoire, sans);

        final DraftMoveStatus status;
        if (covered) {
          status = DraftMoveStatus.inRepertoire;
        } else if (parentCovered) {
          // First move off the book on this line.
          status = isMyMove
              ? DraftMoveStatus.myDeviation
              : DraftMoveStatus.opponentDeviation;
        } else {
          status = DraftMoveStatus.beyondBook;
        }

        out[child] = DraftMoveInfo(
          status: status,
          isMyMove: isMyMove,
          depth: depth,
        );

        walk(child, sans, covered);
      }
    }

    walk(tree.root, const [], true);
    return RepertoireDiff._(out);
  }

  /// Whether [repertoire] contains the exact SAN sequence [sans] from its root.
  static bool _repertoireHasPath(MoveTree repertoire, List<String> sans) {
    if (sans.isEmpty) return true;
    var siblings = repertoire.roots;
    for (final san in sans) {
      MoveNode? match;
      for (final node in siblings) {
        if (node.san == san) {
          match = node;
          break;
        }
      }
      if (match == null) return false;
      siblings = match.children;
    }
    return true;
  }
}
