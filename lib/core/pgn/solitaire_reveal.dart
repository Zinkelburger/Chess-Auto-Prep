/// What a solitaire session lets the movetext show.
///
/// The mainline is revealed up to a frontier ply. Sidelines are either shown
/// wherever they branch below the frontier (a plain session — the game's own
/// notes to the moves you already guessed) or, in a variations drill, only
/// once the drill has reached them. Ephemeral scratch lines — the solver's own
/// wrong tries — are always shown.
library;

import '../../models/move_tree.dart';

class SolitaireReveal {
  /// Mainline moves at index `< mainlinePly` are visible.
  final int mainlinePly;

  /// Sideline nodes revealed so far (by [MoveNode.id]).
  final Set<int> nodeIds;

  /// True while sidelines are being drilled: a saved sideline is hidden until
  /// it is reached, wherever it branches.
  final bool hidesUnreachedSidelines;

  const SolitaireReveal({
    required this.mainlinePly,
    this.nodeIds = const {},
    this.hidesUnreachedSidelines = false,
  });

  /// A plain session with the mainline revealed up to [ply].
  const SolitaireReveal.mainline(int ply) : this(mainlinePly: ply);

  /// Whether a sideline [node] branching at [branchPly] may be shown.
  bool isNodeVisible(MoveNode node, int branchPly) {
    if (node.isEphemeral) return true;
    if (nodeIds.contains(node.id)) return true;
    return !hidesUnreachedSidelines && branchPly < mainlinePly;
  }

  /// Whether the mainline move at [index] may be shown.
  bool isMainlineVisible(int index) => index < mainlinePly;
}
