/// Pure conversion from a parsed PGN tree into per-ply sideline variations.
///
/// Extracted from `pgn_viewer_widget.dart`. These are stateless
/// helpers: given a [PgnGame] and its start position, they build the
/// `ply -> root variation nodes` map the movetext view renders.
library;

import 'package:dartchess/dartchess.dart';

import '../../models/move_tree.dart';
import '../../models/move_tree_pgn.dart';
import '../../utils/chess_utils.dart' show playSanOrNullMove;

/// Walk the parsed PGN mainline and extract sideline variations at each ply.
///
/// The returned map keys are ply numbers (half-move count from the start
/// position along the mainline to the branch point). Key `0` holds variations
/// branching before the first mainline move; key `N` holds variations
/// branching after `N` mainline half-moves.
Map<int, List<MoveNode>> extractPgnVariations(PgnGame game, Position startPos) {
  final result = <int, List<MoveNode>>{};

  PgnNode<PgnNodeData> node = game.moves;
  Position pos = startPos;
  int ply = 0;

  while (node.children.isNotEmpty) {
    final mainChild = node.children[0];

    // Sideline variations at this ply (children[1+])
    if (node.children.length > 1) {
      final variations = MoveTreePgnCodec.nodesFromDartchess(
        node.children.skip(1).toList(),
        pos,
      );
      if (variations.isNotEmpty) {
        result[ply] = variations;
      }
    }

    // Advance along the mainline. Null moves (ChessBase `--` / `Z0`) pass
    // the turn without changing the board so later same-side moves stay legal.
    final next = playSanOrNullMove(pos, mainChild.data.san);
    if (next == null) break;
    pos = next;
    ply++;
    node = mainChild;
  }

  return result;
}
