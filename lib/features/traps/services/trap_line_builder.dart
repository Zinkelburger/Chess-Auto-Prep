/// Builds an annotated, explorable [MoveTree] from a [TrapLineInfo].
///
/// The trap's move sequence becomes the mainline, the trap position gets a
/// summary comment, and the opponent's replies are appended as continuations
/// (popular blunder first, with NAGs, play rates, and our refutation) so the
/// user can step through the whole trap in the PGN editor.
library;

import '../../../models/move_tree.dart';
import '../models/trap_line_info.dart';
import '../models/trap_reply.dart';

class TrapLineBuilder {
  const TrapLineBuilder._();

  /// Annotated tree plus cursor at the trap position.
  ///
  /// Prefers replaying the full SAN sequence from the standard start so the
  /// lead-up moves are visible. When those moves can't be replayed (stale or
  /// corrupt trap file, or a repertoire that doesn't start from the standard
  /// position) but we still know the trap's FEN, it recovers a tree *rooted at
  /// the trap position* — the board still lands on the trap and the annotated
  /// replies (blunder + punish) are still explorable, just without the lead-up.
  /// Returns `null` only when neither the moves nor a FEN are usable.
  static ({MoveTree tree, TreePath cursor})? build(TrapLineInfo trap) =>
      _buildFromMoves(trap) ?? _buildFromFen(trap);

  /// Full line: replay `movesSan` from the standard start, then annotate.
  /// `null` when a SAN fails to parse or the replay lands on a position other
  /// than the recorded trap FEN (moves are relative to a different root).
  static ({MoveTree tree, TreePath cursor})? _buildFromMoves(
    TrapLineInfo trap,
  ) {
    final tree = MoveTree();
    var cursor = TreePath.empty;
    for (final san in trap.movesSan) {
      final next = tree.addMove(cursor, san);
      if (next == null) return null;
      cursor = next;
    }
    if (trap.fen != null &&
        cursor.isNotEmpty &&
        !_samePosition(tree.fenAt(cursor), trap.fen!)) {
      return null;
    }
    if (cursor.isNotEmpty) {
      tree.setComment(cursor, _trapComment(trap));
    }
    _attachReplies(tree, cursor, trap);
    return (tree: tree, cursor: cursor);
  }

  /// Recovery: root the tree at the trap position itself so the board and the
  /// annotated replies survive even when the lead-up moves can't be replayed.
  static ({MoveTree tree, TreePath cursor})? _buildFromFen(TrapLineInfo trap) {
    final fen = trap.fen;
    if (fen == null) return null;
    final MoveTree tree;
    try {
      tree = MoveTree(startingFen: fen);
    } catch (_) {
      return null;
    }
    // Sanity-check the FEN is usable as a root before we hand it back.
    if (tree.addMove(TreePath.empty, trap.popularMove) == null) return null;
    tree.roots.clear();
    _attachReplies(tree, TreePath.empty, trap);
    return (tree: tree, cursor: TreePath.empty);
  }

  /// Append the opponent's replies (blunder first, punished + annotated) as
  /// continuations of the node at [cursor], then promote the blunder so
  /// stepping forward from the trap position walks into it.
  static void _attachReplies(
    MoveTree tree,
    TreePath cursor,
    TrapLineInfo trap,
  ) {
    for (final reply in trap.allReplies ?? _syntheticReplies(trap)) {
      final replyPath = tree.addMove(cursor, reply.san);
      if (replyPath == null) continue;
      final node = tree.nodeAt(replyPath);
      if (node == null) continue;
      node.nags = _nagsFor(reply.classification);
      node.comment = _replyComment(trap, reply);

      if (reply.san == trap.popularMove && trap.refutationMove != null) {
        final refPath = tree.addMove(replyPath, trap.refutationMove!);
        if (refPath != null) {
          final evalText = trap.refutationEvalCp != null
              ? ' (${trap.formatEval(trap.refutationEvalCp!)})'
              : '';
          tree.setComment(refPath, 'Refutation$evalText.');
        }
      }
    }

    // Stepping forward from the trap position should walk into the blunder.
    final trapChildren = cursor.isEmpty
        ? tree.roots
        : tree.nodeAt(cursor)?.children ?? const [];
    final popularIdx = trapChildren.indexWhere(
      (c) => c.san == trap.popularMove,
    );
    if (popularIdx > 0) {
      tree.promoteVariation(cursor.child(popularIdx));
    }
  }

  /// Compare two FENs by piece placement + side to move only, ignoring the
  /// castling / en-passant / clock fields. Generator-side FENs may format those
  /// trailing fields differently from dartchess, and a formatting-only mismatch
  /// must not downgrade an otherwise-correct full replay to a rooted line.
  static bool _samePosition(String a, String b) {
    List<String> key(String fen) =>
        fen.trim().split(RegExp(r'\s+')).take(2).toList();
    final ka = key(a);
    final kb = key(b);
    return ka.length >= 2 && kb.length >= 2 && ka[0] == kb[0] && ka[1] == kb[1];
  }

  /// Fallback replies for legacy trap files without `all_replies`.
  static List<TrapReply> _syntheticReplies(TrapLineInfo trap) => [
    TrapReply(
      san: trap.popularMove,
      probability: trap.popularProb,
      evalAfterCp: trap.popularEvalCp,
      classification: TrapReplyClass.blunder,
    ),
    TrapReply(
      san: trap.bestMove,
      probability: 0,
      evalAfterCp: trap.bestEvalCp,
      classification: TrapReplyClass.good,
    ),
  ];

  static String _trapComment(TrapLineInfo trap) {
    final prob = (trap.popularProb * 100).toStringAsFixed(0);
    final gain = (trap.evalDiffCp / 100).toStringAsFixed(1);
    return '$prob% of opponents play ${trap.popularMove} here, '
        'losing $gain pawns. Best is ${trap.bestMove}.';
  }

  static String _replyComment(TrapLineInfo trap, TrapReply reply) {
    final probPct = reply.probability > 0
        ? '${(reply.probability * 100).toStringAsFixed(0)}%'
        : null;
    final eval = 'eval ${trap.formatEval(reply.evalAfterCp)}';
    final noun = switch (reply.classification) {
      TrapReplyClass.blunder => 'blunder',
      TrapReplyClass.mistake => 'mistake',
      TrapReplyClass.inaccuracy => 'inaccuracy',
      TrapReplyClass.acceptable => 'move',
      TrapReplyClass.good => 'best move',
    };
    final lead = probPct != null
        ? '$probPct play this $noun'
        : noun[0].toUpperCase() + noun.substring(1);
    return '$lead ($eval).';
  }

  /// Standard NAG codes: $4 = ??, $2 = ?, $6 = ?!, $1 = !.
  static List<int>? _nagsFor(TrapReplyClass cls) => switch (cls) {
    TrapReplyClass.blunder => [4],
    TrapReplyClass.mistake => [2],
    TrapReplyClass.inaccuracy => [6],
    TrapReplyClass.acceptable => null,
    TrapReplyClass.good => [1],
  };
}
