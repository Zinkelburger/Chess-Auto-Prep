import 'package:dartchess/dartchess.dart' show Move;

import 'chapter.dart';
import 'chapter_edit.dart';
import 'game_tree.dart';
import 'games_written.dart';
import 'rewrite_gate.dart';
import 'tree_edit.dart';

/// White's evaluation at a mainline position; PV uses UCI moves from there.
final class ReviewValue {
  const ReviewValue(this.cp, this.eval, this.pv);
  final int cp;
  final String eval;
  final List<String> pv;
}

/// Conservative centipawn-loss labels; never overwrite a user's glyph.
int? reviewGlyph(int loss) => loss >= 200
    ? 4
    : loss >= 100
    ? 2
    : loss >= 50
    ? 6
    : null;

ChapterEdit annotateGame(Chapter chapter, List<ReviewValue> values) {
  final index = chapter.game ?? 0;
  if (index >= chapter.lines.length ||
      (chapter.game == null && chapter.lines.length != 1)) {
    return const ChapterEditRefused('Open one game to review it.');
  }
  final line = chapter.lines[index];
  if (!line.isWhole || line.tree == null) {
    return const ChapterEditRefused('This game could not be read in full.');
  }
  var tree = line.tree!;
  var at = const NodePath.root();
  for (var ply = 0; ply < values.length; ply++) {
    final score = values[ply];
    final comment = at.isRoot ? tree.rootComment : tree.nodeAt(at)?.comment;
    final oldAuto = int.tryParse(
      RegExp(
            r'\[%cap_review_nag (\d+)\]',
          ).firstMatch(comment ?? '')?.group(1) ??
          '',
    );
    final kept = (comment ?? '')
        .replaceAll(RegExp(r'\[%eval\s+[^\]]*\]'), '')
        .replaceAll(RegExp(r'\[%cap_review_nag \d+\]'), '')
        .trim();
    tree = withComment(
      tree,
      at,
      '${kept.isEmpty ? '' : '$kept '}[%eval ${score.eval}]',
    );
    if (ply > 0) {
      tree = _reviewMove(tree, at, oldAuto, values[ply - 1], score);
    }
    if (tree.nodeAt(at.mainChild) == null) break;
    at = at.mainChild;
  }
  final rewrittenLine = rewritten(line, tree);
  if (rewrittenLine case LineRefused(:final reason))
    return ChapterEditRefused(reason);
  final lines = [...chapter.lines];
  lines[index] = (rewrittenLine as LineRewritten).line;
  return ChapterEdited(
    withLines(chapter, lines),
    GamesArranged.of(GamesWritten(rewritten: {index}), before: lines.length),
  );
}

GameTree _reviewMove(
  GameTree tree,
  NodePath at,
  int? oldAuto,
  ReviewValue before,
  ReviewValue after,
) {
  if (oldAuto != null) {
    tree = withNodeChanged(
      tree,
      at,
      (node) =>
          withNags(node, node.nags.where((nag) => nag != oldAuto).toList()),
    );
  }
  final node = tree.nodeAt(at)!;
  final loss = (before.cp - after.cp) * (!node.fen.whiteToMove ? 1 : -1);
  final glyph = reviewGlyph(loss);
  if (glyph == null) return tree;
  if (!node.nags.any((n) => n >= 1 && n <= 6)) {
    tree = withNodeChanged(
      tree,
      at,
      (move) => withNodeComment(
        withNags(move, [...move.nags, glyph]),
        '${move.comment ?? ''} [%cap_review_nag $glyph]',
      ),
    );
  }
  return _withAlternative(tree, at.parent, before.pv);
}

/// Reuse existing branches and their notes without replacing or promoting them.
GameTree _withAlternative(GameTree tree, NodePath path, List<String> pv) {
  for (final uci in pv.take(8)) {
    final move = Move.parse(uci);
    final child = move == null ? null : moveNode(tree.fenAt(path), move);
    if (child == null) break;
    final children = path.isRoot ? tree.children : tree.nodeAt(path)!.children;
    var found = children.indexWhere((n) => n.uci == child.uci);
    if (found < 0) {
      found = children.length;
      tree = withChildAdded(tree, path, child);
    }
    path = path.child(found);
  }
  return tree;
}

/// Stored PGN values are White's view and may optionally carry a depth.
ReviewValue? storedReviewValue(String? comment) {
  final token = RegExp(
    r'\[%eval\s+([+-]?(?:\d+(?:\.\d+)?|#-?\d+))(?:,[^\]]*)?\]',
  ).firstMatch(comment ?? '')?.group(1);
  if (token == null) return null;
  if (token.startsWith('#')) {
    final mate = int.tryParse(token.substring(1));
    return mate == null
        ? null
        : ReviewValue(token.startsWith('#-') ? -10000 : 10000, token, const []);
  }
  final pawns = double.tryParse(token);
  return pawns == null || !pawns.isFinite
      ? null
      : ReviewValue((pawns * 100).round(), token, const []);
}
