import 'dart:convert';

import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'pgn_reader.dart';
import 'tree_merge.dart';

/// One game of a chapter file: the line a reader trains and a writer edits.
///
/// The game is the persistent unit, so a line keeps everything a write-back
/// needs — its tags in file order, its own tree (variations included) and
/// its verbatim source. An untouched line is written back byte for byte;
/// only an edited one is generated again.
final class ChapterLine {
  const ChapterLine({
    required this.tags,
    required this.tree,
    required this.text,
    required this.trailer,
  });

  /// Every line of the game's header block, in file order.
  final List<PgnHeader> tags;
  final GameTree tree;

  /// The game's source, with no trailing whitespace.
  final String text;

  /// The whitespace between this game and the next, kept so a file that is
  /// read and written again is unchanged.
  final String trailer;

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
    required this.issues,
  });

  final String name;

  /// The side the repertoire is for; also the board orientation.
  final Side side;

  /// The `//` metadata above the first game, verbatim.
  final String preamble;

  final List<ChapterLine> lines;

  final GameTree tree;

  final List<PgnIssue> issues;

  /// Whether [line] is one of the games merged into [tree].
  bool isInTree(ChapterLine line) => line.tree.rootFen == tree.rootFen;

  /// Games merged into [tree].
  int get gameCount => lines.where(isInTree).length;

  /// Games left out because their root position differs from the first
  /// game's.
  int get skippedGames => lines.length - gameCount;
}

Chapter parseChapter({required String name, required String text}) {
  final document = splitChapterText(text);
  final issues = <PgnIssue>[];
  final lines = <ChapterLine>[];
  for (final (index, game) in document.games.indexed) {
    final read = readPgn(game.text);
    for (final issue in read.issues) {
      issues.add(PgnIssue(game: index, detail: issue.detail));
    }
    final tags = readTags(game.text);
    lines.add(
      ChapterLine(
        tags: tags,
        // A game whose FEN the reader could not use keeps that text as its
        // root, which no other game can equal, so it stays out of the
        // merged tree instead of pretending to start at the chapter root.
        tree: read.games.firstOrNull?.tree ?? _unreadRoot(tags),
        text: game.text,
        trailer: game.trailer,
      ),
    );
  }
  return Chapter(
    name: name,
    side: _side(document.preamble),
    preamble: document.preamble,
    lines: List.unmodifiable(lines),
    tree: mergeLines(lines),
    issues: List.unmodifiable(issues),
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
  issues: chapter.issues,
);

/// [line] carrying [tree]: its tags keep their order and their values, and
/// its text is written again in the format the old app reads.
ChapterLine rewritten(ChapterLine line, GameTree tree) => ChapterLine(
  tags: line.tags,
  tree: tree,
  text: writeGameText(line.tags, tree),
  trailer: line.trailer,
);

/// Every game from the first game's position, folded in file order. The
/// first game fixes the main line; later games can only add variations.
GameTree mergeLines(List<ChapterLine> lines) {
  if (lines.isEmpty) return const GameTree(rootFen: Fen.initial);
  final root = lines.first.tree.rootFen;
  final shared = lines.where((line) => line.tree.rootFen == root);
  return GameTree(
    rootFen: root,
    rootComment: shared.first.tree.rootComment,
    children: shared.fold(
      const <MoveNode>[],
      (merged, line) => mergeForests(merged, line.tree.children),
    ),
  );
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

GameTree _unreadRoot(List<PgnHeader> tags) =>
    GameTree(rootFen: Fen(tagValue(tags, 'FEN') ?? ''));

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
