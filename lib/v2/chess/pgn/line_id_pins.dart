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

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'chapter.dart';
import 'chapter_line.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'games_written.dart';

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

/// The `[LineID]` a game written for [sans] at file position [index] gets.
///
/// It is the id the old app derives for a game that carries no id header —
/// base64url of `"<moves>|<index>"`, truncated to 22 characters after
/// `line_` — so both apps name the same line the same way and the training
/// progress keyed by that name keeps pointing at it.
///
/// Truncation is not collision-free, and two lines sharing one id mix their
/// review histories and let a delete land on the wrong game. An id already
/// in [taken] is therefore replaced by the SHA-256 of the same key, which
/// no shared opening prefix can collide.
String newLineId(List<String> sans, int index, Set<String> taken) {
  final key = '${sans.join(' ')}|$index';
  final short = _shortId(sans, index);
  if (!taken.contains(short)) return short;
  var id = _hashed(key);
  while (taken.contains(id)) {
    id = _hashed('$key|$id');
  }
  return id;
}

String _hashed(String key) =>
    'line_${sha256.convert(utf8.encode(key)).toString().substring(0, 22)}';

/// The id each game of a chapter is trained under, in file order, exactly as
/// the old app assigns them, because both apps key the same progress files by
/// these ids.
///
/// A game's own id header wins; a game without one gets the short id of its
/// moves and its place in the file (see [newLineId]). The first game to claim
/// an id keeps it, so ids already in the progress files stay valid, and every
/// later claimant is given the SHA-256 id of its moves instead — straight to
/// the hash, never the short id, because the id that clashed may have been a
/// header and the short id may already be saved against another game.
///
/// [games] are the games that have moves, each with its place among all the
/// games of the file: a game nothing could read keeps its place, as it does
/// in the old app, so the games after it keep their ids.
///
/// For example two header-less games of one move each, `e4` at 0 and `e4` at
/// 1, get two different short ids; two games both tagged `[LineID "x"]` get
/// `x` and a hash.
List<String> trainingLineIds(
  List<({int index, String? header, List<String> sans})> games,
) {
  final taken = <String>{};
  return [
    for (final game in games)
      _claimed(
        game.header ?? _shortId(game.sans, game.index),
        game.sans,
        game.index,
        taken,
      ),
  ];
}

String _claimed(String id, List<String> sans, int index, Set<String> taken) {
  if (taken.add(id)) return id;
  var hashed = _fullId(sans, index);
  while (!taken.add(hashed)) {
    hashed = _fullId([...sans, hashed], index);
  }
  return hashed;
}

String _shortId(List<String> sans, int index) {
  final encoded = base64Url
      .encode(utf8.encode('${sans.join(' ')}|$index'))
      .replaceAll('=', '');
  return 'line_${encoded.length > 22 ? encoded.substring(0, 22) : encoded}';
}

String _fullId(List<String> sans, int index) =>
    _hashed('${sans.join(' ')}|$index');
