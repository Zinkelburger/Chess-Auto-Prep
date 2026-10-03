/// Keeping a line's training id when an edit would otherwise change it.
///
/// A game with no id header is trained under an id worked out from its main
/// line and its place in the file (see [trainingLineIds]). Edit its moves, or
/// take out or move a game above it, and that id changes, so its schedule,
/// streaks and history are left naming a line that is no longer there. The
/// cure is to write the id down: an edit that rewrites, moves or re-places a
/// game with no id header first gives it `[LineID]` with the id it is trained
/// under now. Both apps read a game's own id header before working one out,
/// so the progress goes on pointing at it in either of them. Of two games
/// carrying one id header only the first with moves is trained under it,
/// so an edit that moves the other one rewrites its header the same way.
///
/// Only games an edit already touches are pinned; a game the edit leaves
/// where it was keeps its bytes and the id they give it.
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';

import 'chapter.dart';
import 'chapter_line.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'games_written.dart';
import 'pgn_reader.dart';
import 'study.dart';
import 'tree_edit.dart';

/// The id each game of [lines] is trained under, in file order; null for a
/// game with no moves or one nothing could read, which is no line but keeps
/// its place, so the ids of the games after it do not move. Such a game
/// still takes the id the old app trains it under, if any, from the games
/// after it ([_claimOf]).
///
/// A game's place is its index in [lines] unless [indexes] gives it one;
/// a whole chapter's games are placed as the old app places them
/// ([trainedIdsOf]).
List<String?> trainedIds(List<ChapterLine> lines, {List<int>? indexes}) =>
    _trainedIds(lines, indexes: indexes);

/// [trainedIds], after [above]: the games the old app makes of the text
/// above the first of [lines], placed from 0, each claiming its id first.
List<String?> _trainedIds(
  List<ChapterLine> lines, {
  List<int>? indexes,
  List<String> above = const [],
}) {
  final claimed = _idsClaimed(
    [
      for (final text in above) _oldAppClaim(text),
      for (final line in lines) _claimOf(line),
    ],
    [
      for (var index = 0; index < above.length; index++) index,
      for (var index = 0; index < lines.length; index++)
        indexes?[index] ?? index,
    ],
  );
  return [
    for (final (index, line) in lines.indexed)
      if (line.tree case final tree? when tree.children.isNotEmpty)
        claimed[above.length + index]
      else
        null,
  ];
}

typedef _Claim = ({String? header, List<String> sans});

/// The id each of [claims] takes at its place in [places], the first to
/// claim an id keeping it ([trainingLineIds]); null for no claim.
List<String?> _idsClaimed(List<_Claim?> claims, List<int> places) {
  final ids = trainingLineIds([
    for (final (index, claim) in claims.indexed)
      if (claim != null)
        (index: places[index], header: claim.header, sans: claim.sans),
  ]);
  var i = 0;
  return [for (final claim in claims) claim == null ? null : ids[i++]];
}

/// The id each game of [chapter] is trained under, each game placed where
/// the old app's parser places it ([oldAppGameIndexes]): a banner above the
/// games moves them all one on there, and both apps must name them alike.
/// Movetext above the first game is a game there, and claims its id first.
List<String?> trainedIdsOf(Chapter chapter) => _trainedIds(
  chapter.lines,
  indexes: oldAppGameIndexes(chapter.preamble, [
    for (final line in chapter.lines) line.text,
  ]),
  above: _aboveGames(chapter),
);

/// Every id a game of [chapter] is known by: the id header it carries, and
/// the id it is trained under, which for a game with no header is worked
/// out from its moves and its place (see [trainingLineIds]). The ids the
/// old app gives the games it makes of the text above the first game are
/// taken too.
///
/// A line added to the chapter must be given none of them. Two games under
/// one id share one review history, and when the game that claimed the id
/// first goes, the other one takes its schedule over.
Set<String> idsInUse(Chapter chapter) {
  final above = _aboveGames(chapter);
  return {
    for (final line in chapter.lines) ?line.lineId,
    ...(chapter.lineIds ?? trainedIdsOf(chapter)).nonNulls,
    ..._idsClaimed(
      [for (final text in above) _oldAppClaim(text)],
      [for (var index = 0; index < above.length; index++) index],
    ).nonNulls,
  };
}

/// The texts of the games the old app makes of the text above [chapter]'s
/// first game ([oldAppPreambleGames]). The last is left out when the first
/// game's `[Event` line is one the old app does not start a game at, which
/// makes it part of that game there.
List<String> _aboveGames(Chapter chapter) {
  final texts = oldAppPreambleGames(chapter.preamble);
  if (texts.isEmpty || chapter.lines.isEmpty) return texts;
  final first = oldAppGameIndexes(chapter.preamble, [
    chapter.lines.first.text,
  ]).single;
  return texts.take(first).toList();
}

/// What [line] claims at its place before any collision: its id header and
/// its main line as the old app spells it, or null for a game the old app
/// trains no line of.
///
/// A game this app reads no moves in, or whose header block the old app
/// ends early, is read as the old app reads it ([_oldAppClaim]): the old
/// app may train it under an id, which no game after it may then take. So
/// is a game reading could not take whole whose main line the old app
/// lexes other moves in, such as one this app stops at an illegal move:
/// the old app works its id out from every move token, legal or not.
_Claim? _claimOf(ChapterLine line) {
  final tree = line.tree;
  if (tree != null &&
      tree.children.isNotEmpty &&
      _oldAppBreakAt(line.tags) < 0) {
    final sans = mainLineSpellings(tree);
    if (!line.isWhole) {
      final old = _oldAppClaim(line.text);
      if (old != null && !const ListEquality<String>().equals(old.sans, sans)) {
        return old;
      }
    }
    return (header: line.lineId, sans: sans);
  }
  return _oldAppClaim(line.text);
}

/// [line], arriving at [place] among a file's games, carrying an id none of
/// [taken] is: its own when that one is free, else a new one from
/// [newLineId]. The id it keeps or gets joins [taken], so no later line can
/// be given it too. A line with no id header is left as it is: arriving
/// after every game already there, it takes no id from any of them. Nor is
/// a line whose id header cannot be rewritten ([withIdHeader]): it sits
/// below where the old app ends the header block, and neither app trains
/// the line under it.
ChapterLine withFreeId(ChapterLine line, int place, Set<String> taken) {
  final id = line.lineId;
  final tree = line.tree;
  if (id == null || tree == null || taken.add(id)) return line;
  final fresh = newLineId(mainlineSans(tree), place, taken);
  final written = withIdHeader(line, fresh);
  if (written == null) return line;
  taken.add(fresh);
  return written;
}

/// The main line's moves as the file spells them, which is what an id is
/// worked out from, in the old app's spelling of castling with digits
/// (`O-O`) and of a null move (`--`) ([_oldAppSpelling]).
List<String> mainLineSpellings(GameTree tree) {
  final sans = <String>[];
  var children = tree.children;
  while (children.isNotEmpty) {
    final move = children.first;
    sans.add(_oldAppSpelling(move.spelling ?? move.san));
    children = move.children;
  }
  return sans;
}

/// [spelling] as the old app spells it when it works an id out: `Z0`,
/// `0000` and `@@@@` are `--`, and castling written with zeros is written
/// with letter O.
String _oldAppSpelling(String spelling) {
  if (spelling == 'Z0' || spelling == '0000' || spelling == '@@@@') {
    return '--';
  }
  return spelling.startsWith('0') ? spelling.replaceAll('0', 'O') : spelling;
}

/// [after], an edit of [before] placed by [games], with every game the edit
/// rewrote or moved whose id would change carrying the id it was trained
/// under in [before], and the arrangement naming those games as rewritten.
///
/// A game whose id header another game above it also carries is trained
/// under an id worked out from its place, so its header is rewritten to that
/// id too. A game that had no id, having no moves, and would now take one a
/// kept line was trained under is given a new one ([newLineId]) instead.
/// Each pin can change which game claims an id first, so the ids are asked
/// again until the edited games all keep theirs.
///
/// Repertoires and studies with per-chapter sides are trainable. Other
/// files opened game by game keep the tags they came with.
({Chapter chapter, GamesArranged games}) withIdsPinned(
  Chapter before,
  Chapter after,
  GamesArranged games,
) {
  if ((before.game != null || after.game != null) &&
      !before.lines.any((line) => studyTrainingSide(line) != null)) {
    return (chapter: after, games: games);
  }
  final moved = [
    for (final (place, from) in games.order.indexed)
      if (from != null &&
          place < after.lines.length &&
          (from != place || games.rewritten.contains(from)))
        (place: place, from: from),
  ];
  if (moved.isEmpty) return (chapter: after, games: games);
  final was = trainedIdsOf(before);
  final kept = {
    for (final from in games.order.nonNulls)
      if (from < was.length) ?was[from],
  };
  final lines = [...after.lines];
  final pinned = <int>{};
  Set<String>? taken;
  for (var changed = true; changed;) {
    changed = false;
    final now = trainedIdsOf(withLines(after, lines));
    for (final (:place, :from) in moved) {
      if (pinned.contains(from)) continue;
      final id = from < was.length ? was[from] : null;
      final line = lines[place];
      final ChapterLine? written;
      if (id != null) {
        // A comment or a glyph leaves the main line, and the id, as they
        // were; a game already naming its id gets it once the one above
        // that took it is pinned.
        if (now[place] == id || line.lineId == id) continue;
        written = withIdHeader(line, id);
      } else {
        final claimed = now[place];
        if (claimed == null || !kept.contains(claimed)) continue;
        taken ??= {...idsInUse(before), ...idsInUse(after)};
        final fresh = newLineId(mainLineSpellings(line.tree!), place, taken);
        written = withIdHeader(line, fresh);
        if (written != null) taken.add(fresh);
      }
      if (written == null) continue;
      lines[place] = written;
      pinned.add(from);
      changed = true;
    }
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
/// nothing here can make that change.
///
/// The header rewritten is the one [ChapterLine.lineId] reads its id from
/// ([idHeaderAt]). A game whose header block the old app ends early gets
/// its `[LineID]` above the line it ends at instead, where both apps read
/// it ([_oldAppBreakAt]). The result is asked again, in both apps' ways: a
/// line whose id does not come back as [id] is refused rather than written.
///
/// The movetext is taken from the line's own bytes rather than written
/// again from its tree, so a line that reading could not take whole still
/// arrives carrying everything it had.
ChapterLine? withIdHeader(ChapterLine line, String id) {
  final at = idHeaderAt(line.tags);
  final List<PgnHeader> tags;
  if (at < 0) {
    final breakAt = _oldAppBreakAt(line.tags);
    final end = breakAt < 0 ? line.tags.length : breakAt;
    // Above the `[Event` line, the game would no longer start there.
    if (end == 0 && line.tags.isNotEmpty) return null;
    final above = end == 0 ? null : line.tags[end - 1];
    tags = [...line.tags]
      ..insert(end, PgnTag('LineID', id, trailer: above?.trailer ?? '\n'));
  } else {
    final was = line.tags[at] as PgnTag;
    tags = [...line.tags]..[at] = PgnTag(was.key, id, trailer: was.trailer);
  }
  final written = withHeaders(line, tags);
  final claim = _claimOf(written);
  final read = written.lineId == id && (claim == null || claim.header == id);
  return read ? written : null;
}

/// [line] carrying [tags] in place of its own, its moves' text untouched.
///
/// The header block is written as [tags] say, so whitespace the file had
/// between two of its tags, which no header keeps, is not written again —
/// as a game written again through the rewrite gate does not write it.
ChapterLine withHeaders(ChapterLine line, List<PgnHeader> tags) {
  // A game with no headers at all has nothing between them and its moves;
  // the first header needs a line of its own.
  final separator = line.tags.isEmpty ? '\n' : line.separator;
  return ChapterLine(
    tags: List.unmodifiable(tags),
    tree: line.tree,
    text: '${headerText(tags)}$separator${movesOf(line)}',
    trailer: line.trailer,
    terminator: line.terminator,
    separator: separator,
    issues: line.issues,
  );
}

/// The line's movetext exactly as the file has it: its own bytes past the
/// headers and the whitespace after them, found where reading the game
/// found them ([movetextStart]).
String movesOf(ChapterLine line) =>
    line.text.substring(movetextStart(line.text));

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

// ---------------------------------------------------------------------------
// The old app's reading of a header block it ends early
// ---------------------------------------------------------------------------
//
// The old app reads a game's headers line by line with [_oldAppTag] and ends
// the block at the first line with anything else on it — a tag value with a
// bare backslash, a bracket that is no tag, a `%` line — and lexes the rest
// as movetext, tag lines included. Only the ids of such a game, of a game
// this app reads no moves in and of the text above the first game, which is
// a game there, are worked out this way; everything else is read as ever.
// This copies `extractHeaderBlock`, `movetextStart` and `mainlineSansOf` in
// lib/chess_core/pgn/mainline_lexer.dart rather than importing them; the two
// must change together.

/// One `[Key "value"]` at the start of a line, as the old app matches it.
final _oldAppTag = RegExp(
  r'^\s*\[([A-Za-z0-9][A-Za-z0-9_+#=:-]*)\s+"((?:[^"\\]|\\"|\\\\)*)"\]',
);

/// The old app's movetext tokens; anything else on a line is skipped.
final _oldAppToken = RegExp(
  r'(?:[NBKRQ]?[a-h]?[1-8]?[-x]?[a-h][1-8](?:=?[nbrqkNBRQK])?|[pnbrqkPNBRQK]?@[a-h][1-8]|O-O-O|0-0-0|O-O|0-0)[+#]?|--|Z0|0000|@@@@|{|;|\$\d{1,4}|[?!]{1,2}|\(|\)|\*|1-0|0-1|1\/2-1\/2',
);

/// The index of the header in [tags] the old app ends the header block at,
/// though this app reads on: a tag it cannot match, or a line that is not a
/// tag after the first one. -1 when it reads the block as this app does;
/// `%` lines above the first tag it skips, as this app does.
int _oldAppBreakAt(List<PgnHeader> tags) {
  var started = false;
  for (final (index, header) in tags.indexed) {
    switch (header) {
      case PgnTag(:final text):
        if (_oldAppTag.firstMatch(text)?.end != text.length) return index;
        started = true;
      case UnparsedHeader(:final text):
        if (started || !text.startsWith('%')) return index;
    }
  }
  return -1;
}

/// What the old app claims for the game [game] before any collision: the
/// id among the tags above the line its header block ends at, the last of
/// each key winning, and every move token from there on outside a comment
/// or a variation, legal or not and past a result. Null when it finds no
/// move, or when a `%` line ends the block, which leaves it none.
_Claim? _oldAppClaim(String game) {
  final text = game.startsWith('\uFEFF') ? game.substring(1) : game;
  final headers = <String, String>{};
  int? moves;
  var inHeaders = false;
  for (var lineStart = 0; lineStart < text.length;) {
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = text.length;
    var line = text.substring(lineStart, lineEnd);
    if (!inHeaders) {
      if (line.trim().isEmpty || line.startsWith('%')) {
        lineStart = lineEnd + 1;
        continue;
      }
      inHeaders = true;
    } else if (line.startsWith('%')) {
      break;
    }
    var consumed = 0;
    for (var m = _oldAppTag.firstMatch(line); m != null;) {
      headers[m[1]!] = m[2]!.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
      consumed += m.end;
      line = line.substring(m.end);
      m = _oldAppTag.firstMatch(line);
    }
    if (line.trim().isNotEmpty) {
      moves = lineStart + consumed;
      break;
    }
    lineStart = lineEnd + 1;
  }
  String? header;
  for (final key in const ['LineID', 'LineId', 'Id', 'Line', 'Guid']) {
    final value = headers[key]?.trim();
    if (value != null && value.isNotEmpty) {
      header = value;
      break;
    }
  }
  final sans = moves == null ? const <String>[] : _oldAppMainLine(text, moves);
  return sans.isEmpty ? null : (header: header, sans: sans);
}

/// The main-line move tokens of [text] from [from] on, as the old app lexes
/// them.
List<String> _oldAppMainLine(String text, int from) {
  final sans = <String>[];
  var depth = 0;
  var lineStart = from;
  // Set when a comment ran past its line: the scan resumes at its `}`.
  var resume = false;
  while (lineStart <= text.length) {
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = text.length;
    if (!resume && text.startsWith('%', lineStart)) {
      lineStart = lineEnd + 1;
      continue;
    }
    resume = false;
    final line = text.substring(lineStart, lineEnd);
    var offset = 0;
    var next = lineEnd + 1;
    tokens:
    for (final match in _oldAppToken.allMatches(line)) {
      if (match.start < offset) continue;
      switch (match[0]!) {
        case ';':
          break tokens;
        case '(':
          depth++;
        case ')':
          if (depth > 0) depth--;
        case '{':
          final close = text.indexOf('}', lineStart + match.end);
          if (close < 0) return sans;
          if (close < lineEnd) {
            offset = close - lineStart + 1;
            continue tokens;
          }
          next = close;
          resume = true;
          break tokens;
        case '*' || '1-0' || '0-1' || '1/2-1/2':
          break;
        case final token when '\$!?'.contains(token[0]):
          break;
        case final token:
          if (depth == 0) sans.add(_oldAppSpelling(token));
      }
    }
    lineStart = next;
  }
  return sans;
}
