import 'chapter.dart';
import 'chapter_edit.dart';
import 'chapter_line.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'games_written.dart';
import 'line_id.dart';
import 'move_text.dart';
import 'rewrite_gate.dart';
import 'tree_edit.dart';
import 'tree_merge.dart';

/// Moving whole lines between chapters: taking them out of one file, adding
/// them to another as games of their own, and folding one into a game that
/// is already there.
///
/// A line is one game, so a line dropped on a chapter is a game appended and
/// a line dropped on a line is two games folded into one. Each of these is
/// an edit to one chapter, because a save writes one file: moving lines from
/// one chapter to another is [linesAddedTo] there and [linesTakenOut] here,
/// two saves the caller orders, and neither half can corrupt the other file.

/// A line nothing could read has no moves to move.
const _unreadableReason = 'a line nothing could read cannot be moved';

/// A line from another starting position has no place in this chapter: its
/// moves would sit in the file where the chapter's tree cannot show them.
const _rootReason = 'that line starts from another position';

/// A line whose text does not begin with the headers it carries, which
/// nothing this app reads produces and nothing here rewrites.
const _headersReason = "a line's moves could not be told from its headers";

/// [chapter] without the games at [games].
///
/// Nothing is read or written back to do it: those games' bytes go and the
/// others stay where they were, exactly as `lineDeleted` does for one. The
/// whitespace between the games that remain stays where the file put it, so
/// a file that ended without a newline goes on ending without one.
///
/// [ChapterUnchanged] when [games] is empty or names no game of the file.
ChapterEdit linesTakenOut(Chapter chapter, {required Set<int> games}) {
  final taking = games
      .where((game) => game >= 0 && game < chapter.lines.length)
      .toSet();
  if (taking.isEmpty) return const ChapterUnchanged();
  final order = [
    for (var index = 0; index < chapter.lines.length; index++)
      if (!taking.contains(index)) index,
  ];
  // In a study the games are the chapters, and a study with no chapters is a
  // file with no games that nothing could open again. The rule holds here
  // rather than only in the panel that usually asks.
  if (chapter.game != null && order.isEmpty) {
    return const ChapterEditRefused('a study needs at least one chapter');
  }
  final lines = [for (final index in order) chapter.lines[index]];
  return ChapterEdited(
    // The chapter on screen is followed by which game it is: taking other
    // games out must not put a different chapter on the board.
    withLines(
      chapter,
      spacedAsBefore(chapter, lines),
      game: _stillShowing(chapter, order),
    ),
    GamesArranged(order: order, before: chapter.lines.length),
  );
}

/// Where the game on the board is once the file holds [order], or null when
/// the chapter is the whole file and there is nothing to follow.
///
/// A game that is still there keeps the board. One that was taken out leaves
/// it on whatever took its place, which is the first game that was below it.
int? _stillShowing(Chapter chapter, List<int> order) {
  final showing = chapter.game;
  if (showing == null) return null;
  final moved = order.indexOf(showing);
  if (moved >= 0) return moved;
  final above = order.where((index) => index < showing).length;
  return above.clamp(0, order.length - 1);
}

/// [chapter] with each of [lines] appended as a game of its own, in the
/// order given.
///
/// This is what dropping lines on a chapter does. A line arrives whole — its
/// name, its id, its review state, its `[FEN]`/`[SetUp]` root and its moves'
/// own bytes — because a line is a game and a game is the persistent unit.
/// The one header this may rewrite is the id: two games sharing one id mix
/// their review histories and let a delete land on the wrong game, so a line
/// whose id the chapter already has gets a fresh one from [newLineId].
///
/// Refused when a line plays from another position than the chapter's. A
/// chapter with no games yet has no position of its own, so the first lines
/// added to it bring theirs.
///
/// Scope: `GamesWritten(appended: n)`, spelled out through
/// [GamesArranged.of] because that is what a [ChapterEdit] carries. It says
/// what `GamesEdited` would: no game already in the file is written again.
ChapterEdit linesAddedTo(Chapter chapter, {required List<ChapterLine> lines}) {
  if (lines.isEmpty) return const ChapterUnchanged();
  final refusal = _rootRefusal(chapter, lines);
  if (refusal != null) return ChapterEditRefused(refusal);
  final added = _withOwnIds(chapter, lines);
  if (added == null) return const ChapterEditRefused(_headersReason);
  return ChapterEdited(
    withLines(
      chapter,
      _appendedTo(chapter, added),
      preamble: _headingFor(chapter),
    ),
    GamesArranged.of(
      GamesWritten(appended: added.length),
      before: chapter.lines.length,
    ),
  );
}

/// Why [lines] cannot become games of [chapter], or null when they can.
String? _rootRefusal(Chapter chapter, List<ChapterLine> lines) {
  // A chapter with no games of its own has no root yet; the first line
  // added to it says what the chapter is from now on.
  final root = chapter.lines.isEmpty
      ? lines.first.tree?.rootFen
      : chapter.tree.rootFen;
  for (final line in lines) {
    final tree = line.tree;
    if (tree == null) return _unreadableReason;
    if (tree.rootFen != root) return _rootReason;
  }
  return null;
}

/// [lines] with an id of their own wherever [chapter] already has the one
/// they carry, or null when such a line's moves cannot be told from its
/// headers.
List<ChapterLine>? _withOwnIds(Chapter chapter, List<ChapterLine> lines) {
  final taken = _takenIds(chapter);
  final out = <ChapterLine>[];
  for (final (offset, line) in lines.indexed) {
    final id = line.lineId;
    final tree = line.tree;
    // A line with no id of its own clashes with nothing; the old app derives
    // one for it from its moves when it needs one.
    if (id == null || tree == null || taken.add(id)) {
      out.add(line);
      continue;
    }
    final at = chapter.lines.length + offset;
    final fresh = newLineId(mainlineSans(tree), at, taken);
    final written = _withIdHeader(line, fresh);
    if (written == null) return null;
    taken.add(fresh);
    out.add(written);
  }
  return out;
}

Set<String> _takenIds(Chapter chapter) => {
  for (final line in chapter.lines) ?line.lineId,
};

/// [line] with the header its id comes from holding [id] instead, its moves'
/// text untouched, or null when nothing here can make that change.
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
ChapterLine? _withIdHeader(ChapterLine line, String id) {
  final had = line.lineId;
  final at = line.tags.indexWhere(
    (header) => header is PgnTag && header.value.trim() == had,
  );
  final moves = _movesOf(line);
  if (at < 0 || moves == null) return null;
  final was = line.tags[at] as PgnTag;
  final tags = [...line.tags]..[at] = PgnTag(was.key, id, trailer: was.trailer);
  final written = ChapterLine(
    tags: List.unmodifiable(tags),
    tree: line.tree,
    text: '${_headerText(tags)}${line.separator}$moves',
    trailer: line.trailer,
    terminator: line.terminator,
    separator: line.separator,
    issues: line.issues,
  );
  return written.lineId == id ? written : null;
}

/// The line's movetext exactly as the file has it: its own bytes past the
/// headers and the whitespace after them.
String? _movesOf(ChapterLine line) {
  final prefix = '${_headerText(line.tags)}${line.separator}';
  return line.text.startsWith(prefix)
      ? line.text.substring(prefix.length)
      : null;
}

String _headerText(List<PgnHeader> tags) {
  final buffer = StringBuffer();
  for (final header in tags) {
    buffer
      ..write(header.text)
      ..write(header.trailer);
  }
  return buffer.toString();
}

/// [chapter]'s games with [added] after them, each starting its own
/// `[Event ` line.
///
/// The game that was last gains the blank line that puts the next one on a
/// line of its own, which is not a game written again — the store compares
/// games by their own bytes, not by the space between them. The last game
/// added takes the whitespace the file ended with, so a file that ended
/// without a newline goes on ending without one.
List<ChapterLine> _appendedTo(Chapter chapter, List<ChapterLine> added) {
  final was = chapter.lines;
  final ending = was.isEmpty ? '\n' : was.last.trailer;
  return [
    for (final (index, line) in was.indexed)
      index == was.length - 1 ? _spacedAfter(line) : line,
    for (final (index, line) in added.indexed)
      index == added.length - 1 ? line.spacedBy(ending) : _spacedAfter(line),
  ];
}

ChapterLine _spacedAfter(ChapterLine line) =>
    line.trailer.endsWith('\n\n') ? line : line.spacedBy('\n\n');

/// The `//` heading with room under it for a first game, or null when it
/// needs none — which is nearly always.
///
/// A heading whose last line does not end would run into the `[Event` of the
/// game appended after it, and a first game nothing can find is a first game
/// lost. Every other heading is left exactly as it is: the heading is not
/// this edit's to write, and the arrangement it declares says so.
String? _headingFor(Chapter chapter) {
  final preamble = chapter.preamble;
  if (chapter.lines.isNotEmpty || preamble.isEmpty || preamble.endsWith('\n')) {
    return null;
  }
  return '$preamble\n\n';
}

/// [chapter] with the moves of [line] folded into the game at [host] as
/// variations wherever the two part.
///
/// This is what dropping a line on a line does: the line stops being a game
/// of its own and becomes the sidelines of one that stays. The host keeps
/// everything it had — its place in the file, its name, its id, its review
/// state, its comments and the order of its moves — because folding keeps
/// the first tree's moves where they are and can only add after them. The
/// host's introduction stands too; the arriving line's is taken only when
/// the host has none, which is the rule folding follows for every other
/// comment.
///
/// [ChapterUnchanged] when the host already plays every move of [line], and
/// when [host] names no game of the file.
///
/// Scope: the one game at [host], written again through the rewrite gate.
ChapterEdit lineGraftedInto(
  Chapter chapter, {
  required int host,
  required ChapterLine line,
}) {
  if (host < 0 || host >= chapter.lines.length) return const ChapterUnchanged();
  final moves = line.tree;
  if (moves == null) return const ChapterEditRefused(_unreadableReason);
  if (moves.rootFen != chapter.tree.rootFen) {
    return const ChapterEditRefused(_rootReason);
  }
  final into = chapter.lines[host];
  final tree = chapter.writableTree(into);
  if (tree == null) return const ChapterEditRefused(lineNotWholeReason);
  final grafted = GameTree(
    rootFen: tree.rootFen,
    rootComment: tree.rootComment ?? moves.rootComment,
    children: mergeForests(tree.children, moves.children),
  );
  if (_writesTheSame(grafted, tree, into.terminator)) {
    return const ChapterUnchanged();
  }
  return _hostRewritten(chapter, host: host, into: into, grafted: grafted);
}

/// Whether the host's moves would come out of the writer unchanged, which is
/// what a line the host already plays every move of leaves behind.
bool _writesTheSame(GameTree grafted, GameTree tree, String? terminator) =>
    grafted.rootComment == tree.rootComment &&
    writeMoveText(grafted, terminator: terminator) ==
        writeMoveText(tree, terminator: terminator);

ChapterEdit _hostRewritten(
  Chapter chapter, {
  required int host,
  required ChapterLine into,
  required GameTree grafted,
}) {
  final written = rewritten(into, grafted);
  if (written case LineRefused(:final reason)) {
    return ChapterEditRefused(reason);
  }
  final lines = [...chapter.lines];
  lines[host] = (written as LineRewritten).line;
  return ChapterEdited(
    withLines(chapter, lines),
    GamesArranged.of(
      GamesWritten(rewritten: {host}),
      before: chapter.lines.length,
    ),
  );
}
