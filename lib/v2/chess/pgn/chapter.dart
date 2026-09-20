import 'dart:convert';

import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'pgn_issue.dart';
import 'pgn_reader.dart';
import 'rewrite_gate.dart';
import 'tree_merge.dart';

/// One game of a chapter file: the line a reader trains and a writer edits.
///
/// The game is the persistent unit, so a line keeps everything a write-back
/// needs — its tags in file order with the endings they had, the whitespace
/// before its moves, its own tree (variations included), the marker it ended
/// with and its verbatim source. An untouched line is written back byte for
/// byte; only an edited one is generated again.
final class ChapterLine {
  const ChapterLine({
    required this.tags,
    required this.tree,
    required this.text,
    required this.trailer,
    required this.terminator,
    required this.separator,
    this.issues = const [],
  });

  /// Every line of the game's header block, in file order.
  final List<PgnHeader> tags;

  /// The game's moves, or null when nothing could read it — a `[FEN]` header
  /// that is not a position.
  final GameTree? tree;

  /// The game's source, with no trailing whitespace.
  final String text;

  /// The whitespace between this game and the next, kept so a file that is
  /// read and written again is unchanged.
  final String trailer;

  /// The game-termination marker the file wrote, or null when it wrote none.
  final String? terminator;

  /// The whitespace between the header block and the first move.
  final String separator;

  /// What the reader could not carry into the model.
  final List<PgnIssue> issues;

  /// Whether an edit may write this game again.
  ///
  /// A game with anything the model does not hold keeps its own bytes and no
  /// edit can reach it, so nothing anyone does elsewhere in the chapter can
  /// take that text away.
  bool get rewritable => tree != null && issues.isEmpty;

  /// The identity every later lookup uses — training progress, rename,
  /// delete. Files in the wild spell it five ways; whichever one a file has
  /// is the line's id.
  String? get lineId {
    for (final key in const ['LineID', 'LineId', 'Id', 'Line', 'Guid']) {
      final value = tagValue(tags, key)?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }
}

/// An issue with the game at [game] in the chapter file, counting from zero.
typedef ChapterIssue = ({int game, PgnIssue issue});

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
      for (final issue in line.issues) (game: index, issue: issue),
  ];

  /// [line]'s moves when an edit may rewrite it: it is one of the games
  /// merged into [tree] and everything it holds survives being written
  /// again. Null when it starts somewhere else, could not be read, or holds
  /// something this app cannot write back.
  GameTree? mergedTree(ChapterLine line) {
    final lineTree = line.tree;
    return line.rewritable &&
            lineTree != null &&
            lineTree.rootFen == tree.rootFen
        ? lineTree
        : null;
  }

  /// Whether [line] is one of the games merged into [tree].
  bool isInTree(ChapterLine line) => mergedTree(line) != null;

  /// Games merged into [tree].
  int get gameCount => lines.where(isInTree).length;

  /// Games nothing could read.
  int get unreadableGames => lines.where((line) => line.tree == null).length;

  /// Games that were read but keep their own bytes, because writing them
  /// again would not give them back.
  int get protectedGames =>
      lines.where((line) => line.tree != null && !line.rewritable).length;

  /// Games left out because their root position differs from the chapter's.
  int get skippedGames =>
      lines.length - gameCount - unreadableGames - protectedGames;
}

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
    side: _side(document.preamble),
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

/// [line] carrying [tree], or [line] untouched when writing it again would
/// not read back as the same game.
///
/// This is the only place a game already in a file becomes new text, so the
/// gate here is the gate for every edit: a caller that cannot write a game
/// gets the game it had, and the chapter keeps those bytes.
ChapterLine rewritten(ChapterLine line, GameTree tree) {
  final written = safeGameText(
    tags: line.tags,
    tree: tree,
    terminator: line.terminator,
    separator: line.separator,
  );
  return switch (written) {
    RewriteRefused() => line,
    RewriteReady(:final text) => ChapterLine(
      tags: line.tags,
      tree: tree,
      text: text,
      trailer: line.trailer,
      terminator: line.terminator,
      separator: line.separator,
    ),
  };
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

/// `// Color: Black` in the preamble reads as Black; anything else,
/// including no line at all, is White. The old app wrote it that way and
/// reads it the same way.
Side _side(String preamble) {
  for (final line in const LineSplitter().convert(preamble)) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('// Color:')) continue;
    final color = trimmed.substring('// Color:'.length).trim().toLowerCase();
    return color == 'black' ? Side.black : Side.white;
  }
  return Side.white;
}
