/// Keeping a line's training id when an edit would otherwise change it.
///
/// A game with no id header is trained under an id worked out from its main
/// line and its place in the file (see [trainingLineIds]). Edit its moves, or
/// take out or move a game above it, and that id changes, so its schedule,
/// streaks and history are left naming a line that is no longer there. The
/// cure is to write the id down: an edit that rewrites, moves or re-places a
/// game with no id header first gives it `[LineID]` with the id it is trained
/// under now. Both apps read a game's own id header before working one out,
/// so the progress goes on pointing at it in either of them.
///
/// Only games an edit already touches are pinned; a game the edit leaves
/// where it was keeps its bytes and the id they give it.
library;

import 'chapter.dart';
import 'chapter_line.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'games_written.dart';
import 'line_id.dart';

/// The id each game of [lines] is trained under, in file order; null for a
/// game with no moves or one nothing could read, which is no line but keeps
/// its place, so the ids of the games after it do not move.
List<String?> trainedIds(List<ChapterLine> lines) {
  final games = [
    for (final (index, line) in lines.indexed)
      if (line.tree case final tree? when tree.children.isNotEmpty)
        (index: index, header: line.lineId, sans: mainLineSpellings(tree)),
  ];
  final claimed = trainingLineIds(games);
  final ids = List<String?>.filled(lines.length, null);
  for (final (i, game) in games.indexed) {
    ids[game.index] = claimed[i];
  }
  return ids;
}

/// The main line's moves as the file spells them, which is what an id is
/// worked out from.
List<String> mainLineSpellings(GameTree tree) {
  final sans = <String>[];
  var children = tree.children;
  while (children.isNotEmpty) {
    final move = children.first;
    sans.add(move.spelling ?? move.san);
    children = move.children;
  }
  return sans;
}

/// [after], an edit of [before] placed by [games], with every game the edit
/// rewrote or moved whose id would change carrying the id it was trained
/// under in [before], and the arrangement naming those games as rewritten.
///
/// Only a repertoire chapter is pinned: a study's or a viewer's games are
/// not trained by id, and their files keep the tags they came with.
({Chapter chapter, GamesArranged games}) withIdsPinned(
  Chapter before,
  Chapter after,
  GamesArranged games,
) {
  if (before.game != null || after.game != null) {
    return (chapter: after, games: games);
  }
  final moved = [
    for (final (place, from) in games.order.indexed)
      if (from != null &&
          place < after.lines.length &&
          (from != place || games.rewritten.contains(from)) &&
          after.lines[place].lineId == null)
        (place: place, from: from),
  ];
  if (moved.isEmpty) return (chapter: after, games: games);
  final was = trainedIds(before.lines);
  final now = trainedIds(after.lines);
  final lines = [...after.lines];
  final pinned = <int>{};
  for (final (:place, :from) in moved) {
    final id = from < was.length ? was[from] : null;
    // A comment or a glyph leaves the main line, and the id, as they were.
    if (id == null || now[place] == id) continue;
    final line = lines[place];
    final written = withIdHeader(line, id);
    if (written == null) continue;
    lines[place] = written;
    pinned.add(from);
  }
  if (pinned.isEmpty) return (chapter: after, games: games);
  return (
    chapter: withLines(after, lines),
    games: GamesArranged(
      order: games.order,
      rewritten: {...games.rewritten, ...pinned},
      before: games.before,
      heading: games.heading,
    ),
  );
}

/// [line] with its id header holding [id], or with `[LineID]` added after
/// its last tag when it has none, its moves' text untouched. Null when
/// nothing here can make that change: the line's text does not begin with
/// the headers it carries.
///
/// Which header the id comes from is [ChapterLine.lineId]'s to say — files
/// in the wild spell the key five ways — so the header is found by the value
/// it holds and the result is then asked again. A line whose id does not
/// come back as [id] is one this rewrote the wrong header of, and it is
/// refused rather than written.
///
/// The movetext is taken from the line's own bytes rather than written
/// again from its tree, so a line that reading could not take whole still
/// arrives carrying everything it had.
ChapterLine? withIdHeader(ChapterLine line, String id) {
  final had = line.lineId;
  final List<PgnHeader> tags;
  if (had == null) {
    final last = line.tags.isEmpty ? null : line.tags.last;
    tags = [...line.tags, PgnTag('LineID', id, trailer: last?.trailer ?? '\n')];
  } else {
    final at = line.tags.indexWhere(
      (header) => header is PgnTag && header.value.trim() == had,
    );
    if (at < 0) return null;
    final was = line.tags[at] as PgnTag;
    tags = [...line.tags]..[at] = PgnTag(was.key, id, trailer: was.trailer);
  }
  final written = withHeaders(line, tags);
  return written?.lineId == id ? written : null;
}

/// [line] carrying [tags] in place of its own, its moves' text untouched, or
/// null when its text does not begin with the headers it carries.
ChapterLine? withHeaders(ChapterLine line, List<PgnHeader> tags) {
  final moves = movesOf(line);
  if (moves == null) return null;
  // A game with no headers at all has nothing between them and its moves;
  // the first header needs a line of its own.
  final separator = line.tags.isEmpty ? '\n' : line.separator;
  return ChapterLine(
    tags: List.unmodifiable(tags),
    tree: line.tree,
    text: '${headerText(tags)}$separator$moves',
    trailer: line.trailer,
    terminator: line.terminator,
    separator: separator,
    issues: line.issues,
  );
}

/// The line's movetext exactly as the file has it: its own bytes past the
/// headers and the whitespace after them.
String? movesOf(ChapterLine line) {
  final prefix = '${headerText(line.tags)}${line.separator}';
  return line.text.startsWith(prefix)
      ? line.text.substring(prefix.length)
      : null;
}

/// [tags] as the file writes them, each followed by its own whitespace.
String headerText(List<PgnHeader> tags) {
  final buffer = StringBuffer();
  for (final header in tags) {
    buffer
      ..write(header.text)
      ..write(header.trailer);
  }
  return buffer.toString();
}
