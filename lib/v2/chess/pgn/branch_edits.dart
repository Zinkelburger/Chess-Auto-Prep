import 'chapter.dart';
import 'chapter_edit.dart';
import 'chapter_line.dart';
import 'game_tree.dart';
import 'games_written.dart';
import 'rewrite_gate.dart';
import 'tree_edit.dart';

/// Editing the shape of a chapter's moves: taking a branch out, and deciding
/// which branch is the main line.
///
/// **Why these are not edits to one tree.** The tree on screen is every game
/// of the chapter merged in file order, so two things decide its shape: the
/// order of the moves inside each game, and the order of the games in the
/// file. The first game that plays a move at a point puts that move first.
///
/// Take a chapter holding three games:
///
///     game 1   1. d4 d5 2. c4 e6
///     game 2   1. d4 Nf6
///     game 3   1. d4 d5 2. c4 c6
///
/// The tree shows `1. d4` with `d5` first, because game 1 gets there first,
/// and `Nf6` second. Making `Nf6` the main line moves game 2 in front of
/// game 1: no game is rewritten at all, and no other byte of the file moves.
/// Promoting a branch that sits inside one game — `3... Nf6` written as a
/// variation of `3... exd5` — instead rewrites that one game. Usually it is
/// both, so the answer is an arrangement: which game of the file each game of
/// the new file is, and which of them were written again.
///
/// Deleting from a move works the same way round: every game that plays it is
/// cut short there, and a game with nothing left is taken out of the file.

/// [chapter] without the move at [at] and everything under it.
///
/// Every game that plays the move is cut short there; no game leaves the
/// file, because a game is where a line's name, id and review state live.
ChapterEdit movesDeleted(Chapter chapter, {required NodePath at}) {
  final sans = _sansTo(chapter, at);
  if (sans == null) return const ChapterUnchanged();
  final lines = <ChapterLine>[];
  final order = <int?>[];
  final written = <int>{};
  for (final (index, line) in chapter.lines.indexed) {
    final tree = chapter.treeInChapter(line);
    final path = tree == null ? null : pathOfSans(tree, sans);
    if (tree == null || path == null) {
      lines.add(line);
      order.add(index);
      continue;
    }
    if (!line.isWhole) return const ChapterEditRefused(lineNotWholeReason);
    // A game whose every move was under that one stays in the file as a game
    // with no moves: its name, its id, its review state and the chapter's
    // introduction are on it, and a deletion of moves is not a reason to
    // lose the line those belong to.
    final cut = withChildRemoved(tree, path.parent, path.indexes.last);
    final result = rewritten(line, cut);
    if (result case LineRefused(:final reason)) {
      return ChapterEditRefused(reason);
    }
    lines.add((result as LineRewritten).line);
    order.add(index);
    written.add(index);
  }
  if (written.isEmpty) return const ChapterUnchanged();
  return ChapterEdited(
    withLines(chapter, spacedAsBefore(chapter, lines)),
    GamesArranged(
      order: order,
      rewritten: written,
      before: chapter.lines.length,
    ),
  );
}

/// [chapter] with the move at [at] first among the moves that share its
/// parent — one level, as a promoted variation is one level.
ChapterEdit variationPromoted(Chapter chapter, {required NodePath at}) {
  final sans = _sansTo(chapter, at);
  if (sans == null) return const ChapterUnchanged();
  return _firstAtEach(chapter, [sans]);
}

/// [chapter] with the move at [at] on the main line from the first move on,
/// which is every step of its path promoted in turn.
ChapterEdit madeMainLine(Chapter chapter, {required NodePath at}) {
  final sans = _sansTo(chapter, at);
  if (sans == null) return const ChapterUnchanged();
  return _firstAtEach(chapter, [
    for (var depth = 1; depth <= sans.length; depth++) sans.sublist(0, depth),
  ]);
}

/// Each of [steps] made the first move at its point, in turn, as one edit.
ChapterEdit _firstAtEach(Chapter chapter, List<List<String>> steps) {
  var current = chapter;
  GamesArranged? arranged;
  for (final sans in steps) {
    final step = _madeFirst(current, sans);
    if (step is ChapterEditRefused) return step;
    if (step is! ChapterEdited) continue;
    current = step.chapter;
    arranged = arranged == null
        ? step.games
        : composedArrangement(arranged, step.games);
    if (arranged == null) {
      return const ChapterEditRefused('the edit could not say what it wrote');
    }
  }
  return arranged == null
      ? const ChapterUnchanged()
      : ChapterEdited(current, arranged);
}

/// Where a game branches at a point, and where the wanted move is there.
typedef _Branch = ({int game, NodePath at, int child});

/// [chapter] with the last move of [sans] first at the point above it.
ChapterEdit _madeFirst(Chapter chapter, List<String> sans) {
  final prefix = sans.sublist(0, sans.length - 1);
  final branches = _branchesAt(chapter, prefix, sans.last);
  final playing = branches.where((branch) => branch.child >= 0).toList();
  if (branches.isEmpty || playing.isEmpty) return const ChapterUnchanged();
  final lines = [...chapter.lines];
  final written = <int>{};
  for (final branch in playing.where((branch) => branch.child > 0)) {
    final line = chapter.lines[branch.game];
    final tree = chapter.treeInChapter(line);
    if (!line.isWhole || tree == null) {
      return const ChapterEditRefused(lineNotWholeReason);
    }
    final moved = withChildFirst(tree, branch.at, branch.child);
    final result = rewritten(line, moved);
    if (result case LineRefused(:final reason)) {
      return ChapterEditRefused(reason);
    }
    lines[branch.game] = (result as LineRewritten).line;
    written.add(branch.game);
  }
  return _reordered(chapter, lines, written, branches.first, playing.first);
}

/// The chapter with the game that plays the move moved in front of the first
/// game that branches at that point, so the merged tree shows it first.
ChapterEdit _reordered(
  Chapter chapter,
  List<ChapterLine> lines,
  Set<int> written,
  _Branch first,
  _Branch mover,
) {
  final order = [for (var index = 0; index < lines.length; index++) index];
  if (mover.game != first.game) {
    order
      ..remove(mover.game)
      ..insert(order.indexOf(first.game), mover.game);
  }
  if (written.isEmpty && mover.game == first.game) {
    return const ChapterUnchanged();
  }
  return ChapterEdited(
    withLines(
      chapter,
      spacedAsBefore(chapter, [for (final index in order) lines[index]]),
    ),
    GamesArranged(
      order: order,
      rewritten: written,
      before: chapter.lines.length,
    ),
  );
}

/// Every game of [chapter] that continues past [prefix], in file order, with
/// where [wanted] sits among that game's moves there — `-1` when that game
/// plays something else.
List<_Branch> _branchesAt(Chapter chapter, List<String> prefix, String wanted) {
  final branches = <_Branch>[];
  for (final (index, line) in chapter.lines.indexed) {
    final tree = chapter.treeInChapter(line);
    final at = tree == null ? null : pathOfSans(tree, prefix);
    if (tree == null || at == null) continue;
    final children = at.isRoot ? tree.children : tree.nodeAt(at)!.children;
    if (children.isEmpty) continue;
    branches.add((
      game: index,
      at: at,
      child: children.indexWhere((node) => node.san == wanted),
    ));
  }
  return branches;
}

/// The moves from the first one down to [at], or null when [at] names no
/// move — the root, or a path this tree does not have.
List<String>? _sansTo(Chapter chapter, NodePath at) {
  if (at.isRoot) return null;
  final line = chapter.tree.lineTo(at);
  if (line.isEmpty) return null;
  return [for (final node in line) node.san];
}
