/// Pure conversion from a parsed PGN tree into per-ply sideline variations.
///
/// Extracted from `pgn_viewer_widget.dart`. These are stateless
/// helpers: given a [PgnGame] and its start position, they build the
/// `ply -> root variation nodes` map the movetext view renders.
library;

import 'package:dartchess/dartchess.dart';

import '../../models/move_tree.dart';

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
      final variations = <MoveNode>[];
      for (int i = 1; i < node.children.length; i++) {
        final sidelineRoot = node.children[i];
        final converted = _convertPgnSubtree(sidelineRoot, pos);
        if (converted != null) variations.add(converted);
      }
      if (variations.isNotEmpty) {
        result[ply] = variations;
      }
    }

    // Advance position along mainline (skip null moves)
    if (mainChild.data.san != '--') {
      final move = pos.parseSan(mainChild.data.san);
      if (move == null) break;
      pos = pos.play(move);
    }
    ply++;
    node = mainChild;
  }

  return result;
}

/// Recursively convert a [PgnChildNode] subtree into a [MoveNode] tree.
MoveNode? _convertPgnSubtree(
  PgnChildNode<PgnNodeData> pgnNode,
  Position posBeforeMove,
) {
  final san = pgnNode.data.san;

  Position posAfter;
  if (san == '--') {
    posAfter = posBeforeMove;
  } else {
    final move = posBeforeMove.parseSan(san);
    if (move == null) return null;
    try {
      posAfter = posBeforeMove.play(move);
    } catch (_) {
      return null;
    }
  }

  final comment =
      (pgnNode.data.comments != null && pgnNode.data.comments!.isNotEmpty)
      ? pgnNode.data.comments!.first
      : null;

  final nags = (pgnNode.data.nags != null && pgnNode.data.nags!.isNotEmpty)
      ? pgnNode.data.nags!.toList()
      : null;

  final node = MoveNode(
    san: san,
    fen: posAfter.fen,
    isEphemeral: false,
    comment: comment,
    nags: nags,
  );

  for (int i = 0; i < pgnNode.children.length; i++) {
    final childNode = _convertPgnSubtree(pgnNode.children[i], posAfter);
    if (childNode != null) node.children.add(childNode);
  }

  return node;
}
