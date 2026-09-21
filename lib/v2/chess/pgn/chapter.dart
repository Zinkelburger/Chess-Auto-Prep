import 'dart:isolate';

import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
import 'chapter_line.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'pgn_issue.dart';
import 'pgn_reader.dart';
import 'study.dart';
import 'tree_merge.dart';

/// A repertoire chapter: the file's preamble, its games, and every game
/// from the same starting position merged into one tree.
///
/// A chapter file is a multi-game PGN where each game is one line, with a
/// `// Color: Black` comment line above the first game saying whose
/// repertoire it is. Games that start somewhere else stay in [lines]
/// untouched and are not part of [tree].
///
/// A study file is the same thing read differently: every game is a chapter
/// of its own, so one of them is the tree and the rest are only listed.
/// [game] says which, and everything below — the tree, the orientation, the
/// counts, which games an edit may write — follows from it. That is the
/// whole difference between the two modes: one document, one session, one
/// board, and a file that says whether the games belong together.
final class Chapter {
  const Chapter({
    required this.name,
    required this.side,
    required this.preamble,
    required this.lines,
    required this.tree,
    this.game,
  });

  final String name;

  /// The side the repertoire is for; also the board orientation.
  final Side side;

  /// The `//` metadata above the first game, verbatim.
  final String preamble;

  final List<ChapterLine> lines;

  final GameTree tree;

  /// The one game of the file [tree] is, counting from zero, or null when
  /// every game from the same position is merged into it.
  final int? game;

  /// The games [tree] is about: all of them, or the one [game] names.
  List<ChapterLine> get treeGames {
    final index = game;
    if (index == null) return lines;
    return index >= 0 && index < lines.length ? [lines[index]] : const [];
  }

  /// Everything no game of [treeGames] could carry into the model, in file
  /// order.
  List<ChapterIssue> get issues => [
    for (final (index, line) in lines.indexed)
      if (game == null || game == index)
        for (final issue in line.issues)
          ChapterIssue(game: index, issue: issue),
  ];

  /// [line]'s own moves when it is one of the games merged into [tree]; null
  /// when it starts somewhere else, could not be read at all, or is another
  /// chapter of the same file.
  GameTree? treeInChapter(ChapterLine line) {
    if (game != null && !treeGames.any((other) => identical(other, line))) {
      return null;
    }
    final lineTree = line.tree;
    return lineTree != null && lineTree.rootFen == tree.rootFen
        ? lineTree
        : null;
  }

  /// [line]'s own moves when an edit may write the game again: it is merged
  /// into [tree] and reading it lost nothing. Null for a game that has to
  /// keep its bytes, which an edit refuses rather than truncates.
  GameTree? writableTree(ChapterLine line) =>
      line.isWhole ? treeInChapter(line) : null;

  /// Whether [line] is one of the games merged into [tree].
  bool isInTree(ChapterLine line) => treeInChapter(line) != null;

  /// Games merged into [tree].
  int get gameCount => treeGames.where(isInTree).length;

  /// Games nothing could read.
  int get unreadableGames =>
      treeGames.where((line) => line.tree == null).length;

  /// Games that were read but keep their own bytes, because writing them
  /// again would not give back everything they hold.
  int get protectedGames =>
      treeGames.where((line) => line.tree != null && !line.isWhole).length;

  /// Games left out because their root position differs from the chapter's.
  int get skippedGames => treeGames.length - gameCount - unreadableGames;
}

/// An issue with the game at [game] of the chapter file, counting from zero.
final class ChapterIssue {
  const ChapterIssue({required this.game, required this.issue});

  final int game;
  final PgnIssue issue;

  /// One plain English sentence fragment naming what was found.
  String get detail => issue.detail;

  @override
  String toString() => 'game $game, $issue';
}

/// [text] as a chapter, read where the screen does not wait for it.
///
/// A small chapter is parsed here and now; a large one — a generated book
/// of thousands of lines — on another isolate, so opening it never holds the
/// window. Same result either way.
/// [game] reads one game of the file as the whole chapter, which is what a
/// study chapter is; null merges the games as a repertoire chapter does.
Future<Chapter> readChapter({
  required String name,
  required String text,
  int? game,
}) => text.length < readOffThreadFrom
    ? Future.value(parseChapter(name: name, text: text, game: game))
    : Isolate.run(() => parseChapter(name: name, text: text, game: game));

/// Below this many characters a chapter is parsed on the calling isolate:
/// the trip to another one costs more than the parse.
const readOffThreadFrom = 64 * 1024;

Chapter parseChapter({required String name, required String text, int? game}) {
  final document = splitChapterText(text);
  final lines = <ChapterLine>[];
  for (final span in document.games) {
    final read = readGame(span.text);
    lines.add(
      ChapterLine(
        tags: read.tags,
        tree: read.tree,
        text: span.text,
        trailer: span.trailer,
        terminator: read.terminator,
        separator: read.separator,
        issues: read.issues,
      ),
    );
  }
  return _built(
    name: name,
    preamble: document.preamble,
    lines: lines,
    game: game,
  );
}

/// [chapter] with [lines] in its place and its tree built again.
///
/// [preamble] replaces the metadata block, which adding the first game to a
/// chapter that had none needs: the new game has to start on its own line.
/// [game] moves the focus, which reordering or removing a study's chapters
/// does: the chapter the user is on keeps its place on screen while its
/// index in the file changes.
Chapter withLines(
  Chapter chapter,
  List<ChapterLine> lines, {
  String? preamble,
  int? game,
}) => _built(
  name: chapter.name,
  preamble: preamble ?? chapter.preamble,
  lines: lines,
  game: game ?? chapter.game,
);

/// A chapter over [lines]: the tree is the one game [game] names, or every
/// game from the same position merged when it names none.
///
/// A focused game is taken as it is rather than merged with itself: merging
/// folds two siblings that play the same move into one, which is right for a
/// repertoire built from separate games and wrong for one game, where the
/// path the file wrote is the path the cursor walks.
Chapter _built({
  required String name,
  required String preamble,
  required List<ChapterLine> lines,
  required int? game,
}) {
  final focused = game != null && game >= 0 && game < lines.length
      ? lines[game]
      : null;
  return Chapter(
    name: name,
    side: focused == null ? chapterSide(preamble) : studyOrientation(focused),
    preamble: preamble,
    lines: List.unmodifiable(lines),
    tree: game == null
        ? mergeLines(lines)
        : focused?.tree ?? const GameTree(rootFen: Fen.initial),
    game: game,
  );
}

/// Every game from the first readable game's position, folded in file order.
/// That game fixes the main line; later games can only add variations.
///
/// The root comes from the first game that could be read, not simply the
/// first game: one unreadable game at the top of a file would otherwise give
/// the chapter a position no other game shares and hide all of them. A file
/// with nothing readable in it has no position of its own, so it reads as an
/// empty chapter from the initial position and says so through
/// [Chapter.unreadableGames] and [Chapter.issues].
GameTree mergeLines(List<ChapterLine> lines) {
  final trees = [for (final line in lines) line.tree].nonNulls;
  if (trees.isEmpty) return const GameTree(rootFen: Fen.initial);
  final root = trees.first.rootFen;
  final shared = trees.where((tree) => tree.rootFen == root);
  return GameTree(
    rootFen: root,
    rootComment: shared.first.rootComment,
    children: shared.fold(
      const <MoveNode>[],
      (merged, tree) => mergeForests(merged, tree.children),
    ),
  );
}

/// [chapter] under another name.
///
/// A chapter is named after its file, so renaming the file renames it. The
/// `//` preamble is left as it is: it is the file's own record of what it was
/// called, and rewriting it would be an edit nobody asked for.
Chapter renamedChapter(Chapter chapter, String name) => Chapter(
  name: name,
  side: chapter.side,
  preamble: chapter.preamble,
  lines: chapter.lines,
  tree: chapter.tree,
  game: chapter.game,
);

/// A chapter file with no games yet: the `//` preamble and nothing else.
///
/// The colour line is the only record of which side the chapter is for, so it
/// is written before there are any moves to infer it from. The stamp is the
/// local time the old app writes, `2026-09-19 14:07:33`, and nothing reads it
/// back; it is there for someone looking at the file.
String newChapterText({
  required String name,
  required Side side,
  required DateTime created,
}) =>
    '// $name\n'
    '// Color: ${side == Side.white ? 'White' : 'Black'}\n'
    '// Created on ${created.toString().split('.').first}\n\n';

/// The chapter file again, byte for byte when nothing was edited.
String writeChapter(Chapter chapter) {
  final buffer = StringBuffer(chapter.preamble);
  for (final line in chapter.lines) {
    buffer
      ..write(line.text)
      ..write(line.trailer);
  }
  return buffer.toString();
}

/// `// Color: Black` in the `//` lines above the first game reads as Black;
/// anything else, including no line at all, is White. The old app wrote it
/// that way and reads it the same way.
///
/// Only the heading is looked at, so asking a large chapter costs nothing:
/// the first line that is neither blank nor a `//` line ends the search.
Side chapterSide(String text) {
  var at = 0;
  while (at < text.length) {
    var end = text.indexOf('\n', at);
    if (end < 0) end = text.length;
    final line = text.substring(at, end).trim();
    at = end + 1;
    if (line.isEmpty) continue;
    if (!line.startsWith('//')) break;
    if (!line.startsWith('// Color:')) continue;
    final color = line.substring('// Color:'.length).trim().toLowerCase();
    return color == 'black' ? Side.black : Side.white;
  }
  return Side.white;
}
