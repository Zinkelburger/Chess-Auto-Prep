import 'package:dartchess/dartchess.dart' show Move;

import '../fen.dart';
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

/// How bad a move was, as the review marks it.
enum ReviewMark {
  inaccuracy(6, 'Inaccuracy'),
  mistake(2, 'Mistake'),
  blunder(4, 'Blunder');

  const ReviewMark(this.nag, this.label);
  final int nag;
  final String label;

  static ReviewMark? ofNag(int nag) =>
      values.where((mark) => mark.nag == nag).firstOrNull;
}

/// Conservative centipawn-loss labels; never overwrite a user's glyph.
ReviewMark? reviewMark(int loss) => loss >= 200
    ? ReviewMark.blunder
    : loss >= 100
    ? ReviewMark.mistake
    : loss >= 50
    ? ReviewMark.inaccuracy
    : null;

int? reviewGlyph(int loss) => reviewMark(loss)?.nag;

/// What the review writes is marked, so it can be taken out again without
/// touching anything the file had: an eval it added, a glyph and its
/// "Mistake. Nf3 was best." note, and a variation it added. A variation's
/// marker counts its moves; files written before that carry the bare form.
const _evalMarker = '[%cap_review_eval]';
final _lineMarker = RegExp(r'\[%cap_review_line(?: (\d+))?\]');
final _nagMarker = RegExp(r'\s*\[%cap_review_nag (\d+)\]');
final _eval = RegExp(r'\s*\[%eval\s+[^\]]*\]');
final _prose = RegExp(r'^(?:Inaccuracy|Mistake|Blunder)\. \S+ was best\.\s*');

bool _marked(String? comment) =>
    comment != null &&
    (comment.contains(_evalMarker) ||
        _lineMarker.hasMatch(comment) ||
        _nagMarker.hasMatch(comment));

/// Whether [tree] carries annotations a review wrote.
bool hasReview(GameTree tree) {
  bool any(List<MoveNode> nodes) =>
      nodes.any((node) => _marked(node.comment) || any(node.children));
  return _marked(tree.rootComment) || any(tree.children);
}

/// [tree] without anything a review wrote.
GameTree withoutReview(GameTree tree) => GameTree(
  rootFen: tree.rootFen,
  rootComment: _unmarked(tree.rootComment),
  children: _unmarkedChildren(tree.children, main: true),
);

List<MoveNode> _unmarkedChildren(
  List<MoveNode> children, {
  required bool main,
}) => List.unmodifiable([
  for (final (index, node) in children.indexed)
    // A review line the user made the game's main line, played on or wrote
    // in is theirs now: only the marks come out.
    if ((main && index == 0) ||
        !_lineMarker.hasMatch(node.comment ?? '') ||
        !_pristineReviewLine(node))
      _unmarkedNode(node, main: main && index == 0),
]);

/// Whether the variation from [head] is still exactly as the review wrote it:
/// one move after another, as many as its marker counts (at most the eight
/// the review writes for the bare marker), with no glyph or note on any.
/// The bare marker of older files carries no count, so a short line the user
/// extended to eight moves or fewer there still reads as the review's.
bool _pristineReviewLine(MoveNode head) {
  final marker = _lineMarker.firstMatch(head.comment!)!;
  final count = int.tryParse(marker.group(1) ?? '');
  if (head.comment!.replaceAll(_lineMarker, '').trim().isNotEmpty) {
    return false;
  }
  var length = 0;
  MoveNode? node = head;
  while (node != null) {
    if (node.children.length > 1 ||
        node.nags.isNotEmpty ||
        node.startingComment != null ||
        (length > 0 && node.comment != null)) {
      return false;
    }
    length++;
    node = node.children.firstOrNull;
  }
  return count == null ? length <= 8 : length == count;
}

MoveNode _unmarkedNode(MoveNode node, {required bool main}) {
  final auto = int.tryParse(
    _nagMarker.firstMatch(node.comment ?? '')?.group(1) ?? '',
  );
  return MoveNode(
    san: node.san,
    uci: node.uci,
    fen: node.fen,
    spelling: node.spelling,
    startingComment: node.startingComment,
    comment: _unmarked(node.comment),
    nags: auto == null
        ? node.nags
        : List.unmodifiable(node.nags.where((nag) => nag != auto)),
    children: _unmarkedChildren(node.children, main: main),
  );
}

String? _unmarked(String? comment) {
  if (!_marked(comment)) return comment;
  var text = comment!;
  if (text.contains(_evalMarker)) {
    text = text.replaceAll(_evalMarker, '').replaceAll(_eval, '');
  }
  if (_nagMarker.hasMatch(text)) {
    text = text.replaceAll(_nagMarker, '').trim().replaceFirst(_prose, '');
  }
  text = text.replaceAll(_lineMarker, '').trim();
  return text.isEmpty ? null : text;
}

ChapterEdit removeReview(Chapter chapter) => _rewriteGame(
  chapter,
  (tree) => hasReview(tree) ? withoutReview(tree) : null,
);

ChapterEdit annotateGame(Chapter chapter, List<ReviewValue> values) =>
    _rewriteGame(chapter, (tree) => _annotated(withoutReview(tree), values));

ChapterEdit _rewriteGame(Chapter chapter, GameTree? Function(GameTree) edit) {
  final index = chapter.game ?? 0;
  if (index >= chapter.lines.length ||
      (chapter.game == null && chapter.lines.length != 1)) {
    return const ChapterEditRefused('Open one game to review it.');
  }
  final line = chapter.lines[index];
  if (!line.isWhole || line.tree == null) {
    return const ChapterEditRefused('This game could not be read in full.');
  }
  final tree = edit(line.tree!);
  if (tree == null) return const ChapterUnchanged();
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

GameTree _annotated(GameTree tree, List<ReviewValue> values) {
  var at = const NodePath.root();
  for (var ply = 0; ply < values.length; ply++) {
    final comment = at.isRoot ? tree.rootComment : tree.nodeAt(at)?.comment;
    // An evaluation the file already had is kept, not replaced.
    if (!(comment ?? '').contains('[%eval')) {
      tree = withComment(
        tree,
        at,
        _joined([comment, '[%eval ${values[ply].eval}]', _evalMarker]),
      );
    }
    if (ply > 0) tree = _reviewMove(tree, at, values[ply - 1], values[ply]);
    if (tree.nodeAt(at.mainChild) == null) break;
    at = at.mainChild;
  }
  return tree;
}

String? _joined(List<String?> parts) {
  final text = parts
      .map((part) => part?.trim() ?? '')
      .where((part) => part.isNotEmpty)
      .join(' ');
  return text.isEmpty ? null : text;
}

GameTree _reviewMove(
  GameTree tree,
  NodePath at,
  ReviewValue before,
  ReviewValue after,
) {
  final node = tree.nodeAt(at)!;
  final loss = (before.cp - after.cp) * (!node.fen.whiteToMove ? 1 : -1);
  final mark = reviewMark(loss);
  if (mark == null) return tree;
  final best = _san(tree.fenAt(at.parent), before.pv.firstOrNull);
  if (best == node.san) return tree;
  if (!node.nags.any((n) => n >= 1 && n <= 6)) {
    tree = withNodeChanged(
      tree,
      at,
      (move) => withNodeComment(
        withNags(move, [...move.nags, mark.nag]),
        _joined([
          best == null ? null : '${mark.label}. $best was best.',
          move.comment,
          '[%cap_review_nag ${mark.nag}]',
        ]),
      ),
    );
  }
  return _withAlternative(tree, at.parent, before.pv);
}

String? _san(Fen fen, String? uci) {
  final move = uci == null ? null : Move.parse(uci);
  return move == null ? null : moveNode(fen, move)?.san;
}

/// Reuse existing branches and their notes without replacing or promoting them.
GameTree _withAlternative(GameTree tree, NodePath path, List<String> pv) {
  NodePath? head;
  var added = 0;
  for (final uci in pv.take(8)) {
    final move = Move.parse(uci);
    final child = move == null ? null : moveNode(tree.fenAt(path), move);
    if (child == null) break;
    final children = path.isRoot ? tree.children : tree.nodeAt(path)!.children;
    var found = children.indexWhere((n) => n.uci == child.uci);
    if (found < 0) {
      found = children.length;
      tree = withChildAdded(tree, path, child);
      head ??= path.child(found);
      added++;
    }
    path = path.child(found);
  }
  return head == null
      ? tree
      : withComment(tree, head, '[%cap_review_line $added]');
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
