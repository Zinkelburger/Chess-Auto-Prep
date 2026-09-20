import 'dart:isolate';

import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
import 'chapter_line.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'pgn_issue.dart';
import 'pgn_reader.dart';
import 'tree_merge.dart';

/// A repertoire chapter: the file's preamble, its games, and every game
/// from the same starting position merged into one tree.
///
/// A chapter file is a multi-game PGN where each game is one line, with a
/// `// Color: Black` comment line above the first game saying whose
/// repertoire it is. Games that start somewhere else stay in [lines]
/// untouched and are not part of [tree].
final class Chapter {
  const Chapter({
    required this.name,
    required this.side,
    required this.preamble,
    required this.lines,
    required this.tree,
  });

  final String name;

  /// The side the repertoire is for; also the board orientation.
  final Side side;

  /// The `//` metadata above the first game, verbatim.
  final String preamble;

  final List<ChapterLine> lines;

  final GameTree tree;

  /// Everything no game could carry into the model, in file order.
  List<ChapterIssue> get issues => [
    for (final (index, line) in lines.indexed)
      for (final issue in line.issues) ChapterIssue(game: index, issue: issue),
  ];

  /// [line]'s own moves when it is one of the games merged into [tree]; null
  /// when it starts somewhere else or could not be read at all.
  GameTree? treeInChapter(ChapterLine line) {
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
  int get gameCount => lines.where(isInTree).length;

  /// Games nothing could read.
  int get unreadableGames => lines.where((line) => line.tree == null).length;

  /// Games that were read but keep their own bytes, because writing them
  /// again would not give back everything they hold.
  int get protectedGames =>
      lines.where((line) => line.tree != null && !line.isWhole).length;

  /// Games left out because their root position differs from the chapter's.
  int get skippedGames => lines.length - gameCount - unreadableGames;
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
Future<Chapter> readChapter({required String name, required String text}) =>
    text.length < readOffThreadFrom
    ? Future.value(parseChapter(name: name, text: text))
    : Isolate.run(() => parseChapter(name: name, text: text));

/// Below this many characters a chapter is parsed on the calling isolate:
/// the trip to another one costs more than the parse.
const readOffThreadFrom = 64 * 1024;

Chapter parseChapter({required String name, required String text}) {
  final document = splitChapterText(text);
  final lines = <ChapterLine>[];
  for (final game in document.games) {
    final read = readGame(game.text);
    lines.add(
      ChapterLine(
        tags: read.tags,
        tree: read.tree,
        text: game.text,
        trailer: game.trailer,
        terminator: read.terminator,
        separator: read.separator,
        issues: read.issues,
      ),
    );
  }
  return Chapter(
    name: name,
    side: chapterSide(document.preamble),
    preamble: document.preamble,
    lines: List.unmodifiable(lines),
    tree: mergeLines(lines),
  );
}

/// [chapter] with [lines] in its place and its tree merged again.
///
/// [preamble] replaces the metadata block, which adding the first game to a
/// chapter that had none needs: the new game has to start on its own line.
Chapter withLines(
  Chapter chapter,
  List<ChapterLine> lines, {
  String? preamble,
}) => Chapter(
  name: chapter.name,
  side: chapter.side,
  preamble: preamble ?? chapter.preamble,
  lines: List.unmodifiable(lines),
  tree: mergeLines(lines),
);

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
);

/// [chapter] played from the other side of the board.
///
/// The side is not a field of the games; it is one `//` line above them, so
/// changing it rewrites that line and leaves every game exactly as it is.
Chapter withSide(Chapter chapter, Side side) => Chapter(
  name: chapter.name,
  side: side,
  preamble: preambleWithSide(chapter.preamble, side),
  lines: chapter.lines,
  tree: chapter.tree,
);

/// [preamble] with its `// Color:` line saying [side].
///
/// Upserted in place: a file that has the line keeps everything around it
/// where it was, and one that has none — an imported PGN, a chapter an older
/// build wrote — gains it above whatever the preamble already said, which is
/// where [chapterSide] looks for it.
String preambleWithSide(String preamble, Side side) {
  final wanted = '// Color: ${side == Side.white ? 'White' : 'Black'}';
  final lines = preamble.split('\n');
  final at = lines.indexWhere((line) => line.trim().startsWith('// Color:'));
  if (at < 0) return '$wanted\n$preamble';
  // A file written on Windows ends that line with a carriage return, and the
  // line beside it keeps one: replacing the words is not a reason to change
  // how the heading ends its lines.
  lines[at] = lines[at].endsWith('\r') ? '$wanted\r' : wanted;
  return lines.join('\n');
}

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
