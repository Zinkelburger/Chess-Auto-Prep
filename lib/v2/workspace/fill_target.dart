import 'dart:isolate';

import 'package:dartchess/dartchess.dart' show Side;

import '../chess/fen.dart';
import '../chess/generation/draft_chapter.dart' show chapterPins;
import '../chess/generation/draft_lines.dart';
import '../chess/generation/search_node.dart';
import '../chess/generation/traps.dart';
import '../chess/pgn/chapter.dart';
import '../chess/pgn/game_tree.dart';
import '../storage/chapter_files.dart';

/// A tree with more nodes than this is cut into lines on another isolate.
const offThreadFrom = 2000;

/// Where a run began and what it may write: a chapter, which gets a draft
/// beside it, or the analysis board, which gets nothing written.
sealed class FillTarget {
  const FillTarget();

  factory FillTarget.chapter(Chapter chapter, ChapterRef source, NodePath at) =
      ChapterTarget;

  factory FillTarget.board(Chapter board, NodePath at, Side side) = BoardTarget;

  Side get side;

  /// The moves already decided, which the search keeps rather than asks.
  Map<String, Set<String>> get pins;

  /// How the log names the run.
  String get label;
}

final class ChapterTarget extends FillTarget {
  const ChapterTarget(this.chapter, this.source, this.cursor);

  final Chapter chapter;
  final ChapterRef source;
  final NodePath cursor;

  @override
  Side get side => chapter.side;

  /// The chapter's own moves: at a position it answers, only its moves are
  /// tried, so a fill continues the chapter rather than second-guessing it.
  @override
  Map<String, Set<String>> get pins => chapterPins(chapter);

  @override
  String get label => source.path;
}

/// The analysis board, for the side at the bottom of it. Nothing on the
/// board is a decision: it is a scratchpad, so nothing is pinned.
final class BoardTarget extends FillTarget {
  BoardTarget(Chapter board, NodePath cursor, this.side)
    : rootFen = board.tree.rootFen,
      line = [
        for (final move in board.tree.lineTo(cursor))
          MoveRef(uci: move.uci, san: move.san),
      ];

  final Fen rootFen;
  final List<MoveRef> line;

  @override
  final Side side;

  @override
  Map<String, Set<String>> get pins => const {};

  @override
  String get label => 'the analysis board';
}

/// The lines [tree] proposes, cut as a draft is, and its traps; worked out
/// on another isolate when the tree is big enough to hold the window
/// otherwise.
Future<(DraftPlan, List<Trap>)> foundIn(
  SearchNode tree, {
  required Set<String> known,
}) {
  (DraftPlan, List<Trap>) work() =>
      (planDraft(linesOf(tree), known: known), trapsOf(tree));
  return nodesIn(tree) < offThreadFrom
      ? Future.value(work())
      : Isolate.run(work);
}

int nodesIn(SearchNode node) => switch (node) {
  OurNode(:final candidates) =>
    1 + candidates.fold(0, (sum, c) => sum + nodesIn(c.child)),
  OpponentNode(:final replies) =>
    1 + replies.fold(0, (sum, r) => sum + nodesIn(r.child)),
  _ => 1,
};
