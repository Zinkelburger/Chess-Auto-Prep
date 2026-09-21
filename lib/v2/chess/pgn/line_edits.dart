import 'package:dartchess/dartchess.dart' show Side;

import 'chapter.dart';
import 'chapter_edit.dart';
import 'chapter_line.dart';
import 'game_text.dart';
import 'games_written.dart';
import 'rewrite_gate.dart';

/// Editing a chapter's lines as lines: what a line is called, whether it is
/// in the file at all, and which side the whole chapter is for.
///
/// A line is one game of the chapter file, so these are edits to whole games
/// — or, for the playing side, to the `//` heading above them. The edits to
/// the shape of the moves are in `branch_edits.dart`.

/// [chapter] with the line at [game] called [name].
///
/// A line's name is its `[Event]` tag, so this writes one header of one game
/// and nothing else; every other game of the file keeps its bytes.
ChapterEdit renamedLine(
  Chapter chapter, {
  required int game,
  required String name,
}) {
  if (game < 0 || game >= chapter.lines.length) {
    return const ChapterUnchanged();
  }
  final line = chapter.lines[game];
  final tree = line.tree;
  if (tagValue(line.tags, 'Event') == name) return const ChapterUnchanged();
  if (!line.isWhole || tree == null) {
    return const ChapterEditRefused(lineNotWholeReason);
  }
  final tags = _named(line.tags, name);
  if (tags == null) {
    return const ChapterEditRefused('that line has no name to change');
  }
  final written = rewritten(_withTags(line, tags), tree);
  if (written case LineRefused(:final reason)) {
    return ChapterEditRefused(reason);
  }
  final lines = [...chapter.lines];
  written as LineRewritten;
  lines[game] = written.line;
  return ChapterEdited(
    withLines(chapter, lines),
    GamesArranged.of(
      GamesWritten(rewritten: {game}),
      before: chapter.lines.length,
    ),
  );
}

/// [chapter] without the line at [game].
///
/// Nothing is read or written back to do it: the game's bytes go and the
/// others stay where they were, so a line nobody could read is as removable
/// as any other. Taking it back is undo, which puts the whole version
/// before this one on disk again.
ChapterEdit lineDeleted(Chapter chapter, {required int game}) {
  if (game < 0 || game >= chapter.lines.length) {
    return const ChapterUnchanged();
  }
  // In a study the games are the chapters, and a study with no chapters is
  // a file with no games that nothing could open again. The rule holds here
  // rather than only in the panel that usually asks.
  if (chapter.game != null && chapter.lines.length <= 1) {
    return const ChapterEditRefused('a study needs at least one chapter');
  }
  final order = [
    for (var index = 0; index < chapter.lines.length; index++)
      if (index != game) index,
  ];
  final lines = [...chapter.lines]..removeAt(game);
  return ChapterEdited(
    // The chapter on screen is followed by which game it is: taking another
    // one out must not put a different chapter on the board.
    withLines(chapter, lines, game: _stillShowing(chapter, order, took: game)),
    GamesArranged(order: order, before: chapter.lines.length),
  );
}

/// Where the game on the board is once the file holds [order], or null when
/// the chapter is the whole file and there is nothing to follow.
int? _stillShowing(Chapter chapter, List<int> order, {required int took}) {
  final showing = chapter.game;
  if (showing == null) return null;
  final moved = order.indexOf(showing);
  return moved >= 0 ? moved : took.clamp(0, order.length - 1);
}

/// [chapter] played from [side], which is also the side the board faces.
ChapterEdit sideSet(Chapter chapter, Side side) {
  if (chapter.side == side) return const ChapterUnchanged();
  return ChapterEdited(
    withSide(chapter, side),
    GamesArranged(
      order: [for (var index = 0; index < chapter.lines.length; index++) index],
      before: chapter.lines.length,
      heading: true,
    ),
  );
}

/// [tags] with the first `[Event]` tag holding [name], or null when there is
/// no such tag to change.
///
/// The tag is written in the standard form rather than the file's, because
/// its value is new; the rest of the header keeps the bytes it had.
List<PgnHeader>? _named(List<PgnHeader> tags, String name) {
  final at = tags.indexWhere((line) => line is PgnTag && line.key == 'Event');
  if (at < 0) return null;
  final was = tags[at] as PgnTag;
  final out = [...tags];
  out[at] = PgnTag('Event', name, trailer: was.trailer);
  return List.unmodifiable(out);
}

ChapterLine _withTags(ChapterLine line, List<PgnHeader> tags) => ChapterLine(
  tags: tags,
  tree: line.tree,
  text: line.text,
  trailer: line.trailer,
  terminator: line.terminator,
  separator: line.separator,
  issues: line.issues,
);
