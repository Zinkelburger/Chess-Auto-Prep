/// PGN movetext round-trip for [MoveTree] nodes: dartchess's parsed game
/// tree in, [MoveNode]s out; [MoveNode]s in, standard movetext out.
library;

import 'package:dartchess/dartchess.dart';

import '../utils/chess_utils.dart' show playSanOrNullMove;
import 'move_tree.dart';

/// Converts between [MoveNode] trees and PGN movetext.
abstract final class MoveTreePgnCodec {
  /// [MoveNode]s for dartchess's parsed [nodes], each carrying the position
  /// reached by playing its SAN from [parentPosition].  A node whose SAN is
  /// illegal there is dropped together with its subtree.
  static List<MoveNode> nodesFromDartchess(
    List<PgnChildNode<PgnNodeData>> nodes,
    Position parentPosition,
  ) {
    final result = <MoveNode>[];
    for (final node in nodes) {
      final san = node.data.san;
      final afterPos = playSanOrNullMove(parentPosition, san);
      if (afterPos == null) continue;
      result.add(
        MoveNode(
          san: san,
          fen: afterPos.fen,
          position: afterPos,
          comment: joinComments(node.data.comments),
          startingComment: joinComments(node.data.startingComments),
          nags: node.data.nags?.toList(),
          children: nodesFromDartchess(node.children, afterPos),
        ),
      );
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

  /// Movetext (no headers, no result token) for [roots] played from a
  /// position with [startMoveNumber] and [startIsWhite] to move, preceded
  /// by [rootComment] when there is one.  Variations are written in PGN's
  /// parenthesised form, mainline first.
  static String moveText({
    required List<MoveNode> roots,
    required int startMoveNumber,
    required bool startIsWhite,
    String? rootComment,
  }) {
    final buffer = StringBuffer();
    if (rootComment != null) {
      buffer.write('{${sanitizeComment(rootComment)}} ');
    }
    if (roots.isNotEmpty) {
      _writeNodes(
        buffer,
        roots,
        startMoveNumber,
        startIsWhite,
        isFirstMove: true,
      );
    }
    return buffer.toString().trim();
  }

  /// A comment body that cannot break out of its `{}` block.
  static String sanitizeComment(String comment) =>
      comment.replaceAll('{', '').replaceAll('}', '');

  static void _writeNodes(
    StringBuffer buffer,
    List<MoveNode> siblings,
    int moveNumber,
    bool isWhite, {
    bool isFirstMove = false,
  }) {
    if (siblings.isEmpty) return;

    final main = siblings[0];
    _writeMove(
      buffer,
      main,
      moveNumber,
      isWhite,
      numbered: isWhite || isFirstMove,
    );

    final nextMoveNumber = isWhite ? moveNumber : moveNumber + 1;
    for (final variant in siblings.skip(1)) {
      buffer.write('(');
      _writeMove(buffer, variant, moveNumber, isWhite, numbered: true);
      _writeNodes(buffer, variant.children, nextMoveNumber, !isWhite);
      buffer.write(') ');
    }

    _writeNodes(buffer, main.children, nextMoveNumber, !isWhite);
  }

  /// One move with its starting comment, number indicator (`3.` / `3...`
  /// when [numbered]), NAGs and trailing comment.
  static void _writeMove(
    StringBuffer buffer,
    MoveNode node,
    int moveNumber,
    bool isWhite, {
    required bool numbered,
  }) {
    final starting = node.startingComment;
    if (starting != null && starting.isNotEmpty) {
      buffer.write('{${sanitizeComment(starting)}} ');
    }
    if (numbered) {
      buffer.write(isWhite ? '$moveNumber. ' : '$moveNumber... ');
    }
    buffer.write('${node.san} ');
    for (final nag in node.nags ?? const <int>[]) {
      buffer.write('\$$nag ');
    }
    final comment = node.comment;
    if (comment != null && comment.isNotEmpty) {
      buffer.write('{${sanitizeComment(comment)}} ');
    }
  }
}
