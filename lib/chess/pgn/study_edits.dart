import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
import 'chapter.dart';
import 'chapter_edit.dart';
import 'chapter_line.dart';
import 'game_tree.dart';
import 'games_written.dart';
import 'pgn_reader.dart';
import 'rewrite_gate.dart';
import 'study.dart';

/// Editing a study's chapters: pure functions from one [Chapter] to the next.
///
/// A study's chapters are the games of its file, so adding, renaming,
/// reordering and deleting one are all edits to the file's game list. Each
/// says what it did to that list, because the store checks a save against
/// what the edit declared and nothing else.

/// A new chapter at the end of the study, which is what the file's game
/// order means by last, and the focus moved onto it. [moves] are its moves
/// from [root], when it is made from a board that has some.
ChapterEdit addChapter(
  Chapter chapter, {
  required String study,
  required String name,
  required Side orientation,
  Fen root = Fen.initial,
  GameTree? moves,
}) => addChapters(
  chapter,
  study: study,
  drafts: [
    ChapterDraft(
      name: name,
      orientation: orientation,
      moves: moves ?? GameTree(rootFen: root),
    ),
  ],
);

/// [drafts] as new chapters at the end of the study, in order, with the
/// focus on the first of them. A draft with no name is called `Chapter N`.
///
/// Every game already in the file is kept byte for byte; only the one that
/// was last gains the whitespace that separates it from the next.
ChapterEdit addChapters(
  Chapter chapter, {
  required String study,
  required List<ChapterDraft> drafts,
}) {
  final ending = _endingIn(chapter);
  var lines = chapter.lines;
  for (final draft in drafts) {
    final name = draft.name.trim().isEmpty
        ? nextChapterName(studyChapters(lines))
        : draft.name.trim();
    final text = studyChapterText(
      draft,
      study: study,
      name: name,
      ending: ending,
    );
    final read = readGame(text);
    if (read.issues.isNotEmpty || read.tree == null) {
      return ChapterEditRefused(
        '"$name" cannot be written as a chapter: '
        '${read.issues.firstOrNull?.detail ?? 'it is not a position'}.',
      );
    }
    final added = ChapterLine(
      tags: read.tags,
      tree: read.tree,
      text: text,
      trailer: '',
      terminator: read.terminator,
      separator: read.separator,
    );
    lines = _withNewGameAtTheEnd(lines, added, ending);
  }
  final before = chapter.lines.length;
  return ChapterEdited(
    withLines(chapter, lines, game: before),
    GamesArranged.of(GamesWritten(appended: drafts.length), before: before),
  );
}

/// The chapter at [index] under another name, with the study's own tags
/// written again and every other tag of that game kept.
ChapterEdit renameChapter(
  Chapter chapter, {
  required String study,
  required int index,
  required String name,
}) => _retagged(chapter, study: study, index: index, name: name);

/// The chapter at [index] facing [orientation]. The board turns with it when
/// it is the chapter on screen, because the board faces [Chapter.side] and
/// that is read from this tag.
ChapterEdit setChapterOrientation(
  Chapter chapter, {
  required String study,
  required int index,
  required Side orientation,
}) => _retagged(chapter, study: study, index: index, orientation: orientation);

/// The chapter at [index] moved [by] places, one at a time through the row
/// menu. A move past either end changes nothing.
ChapterEdit moveChapter(
  Chapter chapter, {
  required int index,
  required int by,
}) {
  final to = index + by;
  if (!_holds(chapter, index) || !_holds(chapter, to)) {
    return ChapterEditRefused(
      by < 0
          ? 'That chapter is already first.'
          : 'That chapter is already last.',
    );
  }
  final order = [for (var i = 0; i < chapter.lines.length; i++) i];
  order.insert(to, order.removeAt(index));
  return _inOrder(chapter, order, focus: _stillShowing(chapter, order));
}

/// The study without the chapter at [index]. The last chapter stays: a study
/// with no chapters is a file with no games, which nothing could open again.
ChapterEdit deleteChapter(Chapter chapter, {required int index}) {
  if (chapter.lines.length <= 1) {
    return const ChapterEditRefused('A study needs at least one chapter.');
  }
  if (!_holds(chapter, index)) {
    return const ChapterEditRefused('That chapter is no longer in the study.');
  }
  final order = [
    for (var i = 0; i < chapter.lines.length; i++)
      if (i != index) i,
  ];
  return _inOrder(
    chapter,
    order,
    // The chapter that took the deleted one's place, for the case where the
    // one on screen is the one that went.
    focus: _stillShowing(chapter, order, took: index),
  );
}

/// The chapter at [index] with the study's six tags written again from what
/// it says now, [name] and [orientation] overriding what the file holds.
ChapterEdit _retagged(
  Chapter chapter, {
  required String study,
  required int index,
  String? name,
  Side? orientation,
}) {
  if (!_holds(chapter, index)) {
    return const ChapterEditRefused('That chapter is no longer in the study.');
  }
  final line = chapter.lines[index];
  final tree = line.tree;
  if (tree == null || !line.isWhole) {
    return const ChapterEditRefused(
      'That chapter was not read whole, so it keeps the text it has.',
    );
  }
  final retagged = ChapterLine(
    tags: withStudyTags(
      line.tags,
      study: study,
      chapter: name ?? studyChapterName(line, index: index, study: study),
      orientation: orientation ?? studyOrientation(line),
      root: tree.rootFen,
    ),
    tree: tree,
    text: line.text,
    trailer: line.trailer,
    terminator: line.terminator,
    separator: line.separator,
  );
  final written = rewritten(retagged, tree);
  if (written case LineRefused(:final reason)) {
    return ChapterEditRefused('The chapter could not be written: $reason.');
  }
  final lines = [...chapter.lines];
  lines[index] = (written as LineRewritten).line;
  return ChapterEdited(
    withLines(chapter, lines),
    GamesArranged.of(
      GamesWritten(rewritten: {index}),
      before: chapter.lines.length,
    ),
  );
}

/// Where the chapter on screen is once the games are in [order].
///
/// It is followed by which game it is, not by where it sat: moving or
/// deleting some other chapter must leave the same chapter on the board, or
/// the next move the user plays is written into a chapter they never opened.
/// [took] is the place a deleted chapter left, which is where the board goes
/// when the chapter on screen is the one that went.
int _stillShowing(Chapter chapter, List<int> order, {int? took}) {
  final showing = chapter.game;
  if (showing == null) return 0;
  final moved = order.indexOf(showing);
  if (moved >= 0) return moved;
  return took == null ? 0 : took.clamp(0, order.length - 1);
}

/// The study holding its games in [order], each byte for byte as it is now,
/// with the focus on the game at [focus] of the new order.
///
/// The whitespace stays where the file had it rather than travelling with
/// the game that moved, so a file written with CRLF, or one that ends
/// without a newline, comes back the way it went in.
ChapterEdit _inOrder(Chapter chapter, List<int> order, {required int focus}) {
  final moved = [for (final from in order) chapter.lines[from]];
  return ChapterEdited(
    withLines(chapter, spacedAsBefore(chapter, moved), game: focus),
    GamesArranged(order: order, before: chapter.lines.length),
  );
}

/// The games [was] with [added] after them, in a file whose lines end with
/// [ending].
///
/// The game that was last gains only what it needs to stop the new game's
/// first header running onto its last line, in the whitespace this file
/// already puts between two games — so a CRLF study stays CRLF. What the
/// file ended with becomes what it ends with again, after the new game.
///
/// It works on the list alone, so adding many chapters builds the study's
/// tree once, not once per chapter.
List<ChapterLine> _withNewGameAtTheEnd(
  List<ChapterLine> was,
  ChapterLine added,
  String ending,
) {
  if (was.isEmpty) return [added.spacedBy(ending)];
  return [
    for (final (index, line) in was.indexed)
      // The game that was last is now followed by another, so it takes the
      // whitespace this file puts between two games.
      index == was.length - 1
          ? line.spacedBy(_betweenGames(was, ending))
          : line,
    added.spacedBy(was.last.trailer),
  ];
}

/// The whitespace [was] already has between two games, or a blank line in
/// [ending] when it has only one game to look at.
String _betweenGames(List<ChapterLine> was, String ending) =>
    was.length > 1 ? was.first.trailer : '$ending$ending';

/// The line ending this file is written with, read from the whitespace it
/// already has rather than assumed.
String _endingIn(Chapter chapter) {
  for (final line in chapter.lines) {
    if (line.trailer.contains('\r\n') || line.separator.contains('\r\n')) {
      return '\r\n';
    }
    if (line.tags.any((tag) => tag.trailer.contains('\r\n'))) return '\r\n';
  }
  return '\n';
}

bool _holds(Chapter chapter, int index) =>
    index >= 0 && index < chapter.lines.length;
