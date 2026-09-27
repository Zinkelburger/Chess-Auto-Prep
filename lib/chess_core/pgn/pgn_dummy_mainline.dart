/// Chessable intro chapters write a dummy null-move mainline whose only
/// alternative is the real lesson (`1. Z0 (1. d4 Z0 2. Nf3 …)`). Promoting
/// that alternative makes the viewer, FEN index, and opening tree see the
/// same mainline instead of hiding the course text in a sideline.
library;

import 'package:dartchess/dartchess.dart';

import '../../utils/chess_utils.dart' show isNullMoveSan;

/// If [root]'s mainline is a childless null move with exactly one
/// alternative, splice that alternative in as the mainline.
///
/// Idempotent: a second call sees a real first move and returns.
void promoteNullMoveDummyMainline(PgnNode<PgnNodeData> root) {
  if (root.children.length != 2) return;
  final dummy = root.children.first;
  if (!isNullMoveSan(dummy.data.san)) return;
  if (dummy.children.isNotEmpty) return;

  final promoted = root.children[1];
  final carried = [
    ...?dummy.data.startingComments,
    ...?dummy.data.comments,
  ].where((c) => c.trim().isNotEmpty);
  if (carried.isNotEmpty) {
    promoted.data.startingComments = [
      ...carried,
      ...?promoted.data.startingComments,
    ];
  }
  root.children.removeAt(0);
}
