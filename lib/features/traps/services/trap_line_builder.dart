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

  /// Annotated tree plus cursor at the trap position, or `null` when the
  /// stored SAN sequence fails to parse (corrupt/stale trap file).
  static ({MoveTree tree, TreePath cursor})? build(TrapLineInfo trap) {
    final tree = MoveTree();
    var cursor = TreePath.empty;
    for (final san in trap.movesSan) {
      final next = tree.addMove(cursor, san);
      if (next == null) return null;
      cursor = next;
    }

    if (cursor.isNotEmpty) {
      tree.setComment(cursor, _trapComment(trap));
    }

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
          tree.setComment(refPath, 'The punish$evalText.');
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

    return (tree: tree, cursor: cursor);
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
    return 'Trap: $prob% of opponents play ${trap.popularMove}, '
        'handing us $gain pawns. Best is ${trap.bestMove}.';
  }

  static String _replyComment(TrapLineInfo trap, TrapReply reply) {
    final prob = reply.probability > 0
        ? '${(reply.probability * 100).toStringAsFixed(0)}% play this'
        : null;
    final eval = 'eval ${trap.formatEval(reply.evalAfterCp)}';
    final label = switch (reply.classification) {
      TrapReplyClass.blunder => 'the blunder we hope for',
      TrapReplyClass.mistake => 'a mistake',
      TrapReplyClass.inaccuracy => 'an inaccuracy',
      TrapReplyClass.acceptable => null,
      TrapReplyClass.good => 'best defence',
    };
    return [prob, eval, label].whereType<String>().join(' — ');
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
