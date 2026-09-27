/// Decode dartchess PGN nodes into the legacy editable move core.
/// Read-only movetext serialization lives in chess_core/pgn/move_text_writer.dart.
library;

import 'package:dartchess/dartchess.dart';

import '../utils/chess_utils.dart' show playSanOrNullMove;
import 'move_tree.dart';

/// Constructs editable [MoveNode] trees from parsed PGN.
abstract final class MoveTreePgnCodec {
  /// [MoveNode]s for dartchess's parsed [nodes], each carrying the position
  /// reached by playing its SAN from [parentPosition].  A node whose SAN is
  /// illegal there is dropped together with its subtree. Iterative traversal
  /// avoids silently turning a deep valid game into an empty tree on overflow.
  static List<MoveNode> nodesFromDartchess(
    List<PgnChildNode<PgnNodeData>> nodes,
    Position parentPosition,
  ) {
    final result = <MoveNode>[];
    final pending = [
      for (final node in nodes.reversed) (node, parentPosition, result),
    ];
    while (pending.isNotEmpty) {
      final (node, parent, output) = pending.removeLast();
      final san = node.data.san;
      final afterPos = playSanOrNullMove(parent, san);
      if (afterPos == null) continue;
      final copy = MoveNode(
        san: san,
        fen: afterPos.fen,
        position: afterPos,
        comment: joinComments(node.data.comments),
        startingComment: joinComments(node.data.startingComments),
        nags: node.data.nags?.toList(),
      );
      output.add(copy);
      for (final child in node.children.reversed) {
        pending.add((child, afterPos, copy.children));
      }
    }
    return result;
  }

  /// The `{}` blocks of one move as a single trimmed string, or null when
  /// there is nothing in them.
  static String? joinComments(List<String>? comments) {
    if (comments == null) return null;
    final joined = comments
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .join(' ');
    return joined.isEmpty ? null : joined;
  }
}
