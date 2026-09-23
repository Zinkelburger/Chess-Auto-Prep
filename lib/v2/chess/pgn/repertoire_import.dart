/// A PGN somebody else wrote, read as the chapters of a repertoire.
///
/// A repertoire chapter is one game per line, and every reader of one — the
/// trainer, the outline, the gap walk — follows each game's main line only.
/// A course or a study keeps most of its theory in brackets, so importing it
/// as written would train one line per chapter and lose the rest. The import
/// therefore writes each root-to-leaf path of a game as a game of its own,
/// once, so that what is on disk is exactly what every reader expects.
///
/// A file that carries chapters — a Lichess study export, where every game
/// is a chapter with its `ChapterName`; a Chessable course, where the games
/// of a chapter share a player header — becomes one chapter per title. One
/// that does not is one chapter.
///
/// Pure: text in, chapter texts out. Which folder they go into and what the
/// files are called is the library's business.
library;

import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
import 'chapter.dart';
import 'chapter_grouping.dart';
import 'chapter_line.dart';
import 'chapter_sections.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'line_id_pins.dart';
import 'pgn_reader.dart';
import 'repertoire_side.dart';

/// What an import found: the chapters to write, or nothing worth writing.
sealed class ImportRead {
  const ImportRead();
}

/// The chapters, in the order the file gave them, each holding at least one
/// line, and the side they appear to be for when the file said or the moves
/// made it plain.
final class ImportedChapters extends ImportRead {
  const ImportedChapters({
    required this.chapters,
    required this.lines,
    required this.side,
  });

  final List<ImportedChapter> chapters;

  /// Lines over every chapter, each variation counted as its own.
  final int lines;

  /// Null when the file did not say and the moves did not make it plain, in
  /// which case the user is asked once when the chapter opens.
  final Side? side;
}

/// Not one game with a move in it.
final class NothingToImport extends ImportRead {
  const NothingToImport();
}

/// One chapter to write: its title as the file gave it, and its text with
/// the `//` heading already on it.
final class ImportedChapter {
  const ImportedChapter({
    required this.title,
    required this.text,
    required this.lines,
  });

  final String title;
  final String text;
  final int lines;
}

/// Reads [text] as chapters. [created] is written into each heading.
ImportRead readImport(String text, {required DateTime created}) {
  final document = splitChapterText(text);
  final games = [
    for (final span in document.games) _Game(span.text, readGame(span.text)),
  ];
  if (!games.any((game) => game.hasMoves)) return const NothingToImport();
  final grouping = _grouping(games);
  final chapters = <ImportedChapter>[];
  var lines = 0;
  final side =
      statedSide(document.preamble) ??
      inferredRepertoireSide([
        for (final game in games)
          if (game.hasMoves && !game.isComplete) game.read.tree!,
      ]);
  for (final group in grouping.groups) {
    final written = _Lines(grouping.titleKey);
    for (final game in group.games) {
      if (!game.hasMoves && game.read.tree != null) continue;
      if (game.read.tree == null) {
        // Nothing could read it, so nothing here can rewrite it: it goes in
        // as its own bytes, and the chapter says so when it opens.
        written.keep(game.text);
        continue;
      }
      final whole = group.modelGames || game.isComplete;
      for (final line in whole ? [game.text] : _expanded(game, grouping)) {
        written.keep(line);
      }
    }
    if (written.count == 0) continue;
    chapters.add(
      ImportedChapter(
        title: group.title,
        lines: written.count,
        text: _chapterText(
          title: group.title,
          side: side,
          course: group.course,
          created: created,
          games: written.text,
        ),
      ),
    );
    lines += written.count;
  }
  if (chapters.isEmpty) return const NothingToImport();
  return ImportedChapters(chapters: chapters, lines: lines, side: side);
}

/// [read]'s chapters as one course file: one heading, then every chapter's
/// lines in order, each naming its chapter in `[ChapterName]` and carrying
/// the `[LineID]` it is trained under, so no later edit or move can change
/// it. A file of one chapter is that chapter's own text, untagged.
///
/// A line whose headers cannot take a tag — nothing this import writes —
/// goes in as it was, and reads as the file's chapter of unnamed games.
String courseText(ImportedChapters read, {required DateTime created}) {
  if (read.chapters.length == 1) return read.chapters.single.text;
  final lines = <ChapterLine>[];
  for (final chapter in read.chapters) {
    for (final line in parseChapter(name: '', text: chapter.text).lines) {
      lines.add(withSection(line, chapter.title) ?? line);
    }
  }
  final ids = trainedIds(lines);
  final heading = StringBuffer();
  if (read.side case final side?) {
    heading.write('// Color: ${side == Side.white ? 'White' : 'Black'}\n');
  }
  heading.write('// Created on ${created.toString().split('.').first}\n\n');
  return [
    heading.toString(),
    for (final (index, line) in lines.indexed)
      '${_pinned(line, ids[index]).text}\n\n',
  ].join().replaceFirst(RegExp(r'\n+$'), '\n');
}

ChapterLine _pinned(ChapterLine line, String? id) =>
    id == null || line.lineId != null ? line : withIdHeader(line, id) ?? line;

/// The `//` heading the old app writes, then the games. `// Chapter:` names
/// the course chapter a file is, which the old app's readers group by.
String _chapterText({
  required String title,
  required Side? side,
  required bool course,
  required DateTime created,
  required String games,
}) {
  final heading = StringBuffer('// $title\n');
  if (side != null) {
    heading.write('// Color: ${side == Side.white ? 'White' : 'Black'}\n');
  }
  if (course) heading.write('// Chapter: $title\n');
  heading.write('// Created on ${created.toString().split('.').first}\n\n');
  return '$heading$games';
}

final class _Game {
  _Game(this.text, this.read);

  final String text;
  final GameRead read;

  bool get hasMoves => read.tree?.children.isNotEmpty ?? false;

  String? tag(String key) => tagValue(read.tags, key);

  /// A game with a result is somebody's finished game: its brackets are
  /// annotation, not repertoire, and it is kept as it is.
  bool get isComplete {
    final result = (tag('Result') ?? '*').trim();
    return result.isNotEmpty && result != '*';
  }
}

// ---------------------------------------------------------------------------
// Which games belong together
// ---------------------------------------------------------------------------

final class _Group {
  _Group(this.title, {required this.course}) : games = [];

  final String title;

  /// Whether the title is a course chapter's, which the heading records.
  final bool course;

  final List<_Game> games;

  /// A course's "Model Games" chapter holds whole games shown as
  /// illustration; they are kept whole rather than cut into lines.
  bool get modelGames => _modelGames.hasMatch(title);
}

final RegExp _modelGames = RegExp(r'\bmodel\s*games?\b', caseSensitive: false);

final class _Grouping {
  const _Grouping(
    this.groups, {
    required this.chapterKey,
    required this.titleKey,
  });

  final List<_Group> groups;

  /// The header the chapters are titled in, or null when there are none.
  final String? chapterKey;

  /// The header a line is titled in: where a sideline's branch label goes.
  final String titleKey;
}

/// The games under their chapter titles, in the order the titles first
/// appear; see [groupChapters].
_Grouping _grouping(List<_Game> games) {
  final grouping = groupChapters([for (final game in games) game.read.tags]);
  final groups = <String, _Group>{};
  for (final (index, title) in grouping.titles.indexed) {
    groups
        .putIfAbsent(title, () => _Group(title, course: grouping.hasChapters))
        .games
        .add(games[index]);
  }
  return _Grouping(
    groups.values.toList(),
    chapterKey: grouping.chapterKey,
    titleKey: grouping.titleKey,
  );
}

// ---------------------------------------------------------------------------
// One game per line
// ---------------------------------------------------------------------------

/// The header every expanded sideline carries: the plies, counted from the
/// game's start, at which it left the first-child path. Once the brackets
/// are gone it is the only trace of whose alternative the line was: a
/// bracket at the opponent's move is coverage, one at ours is the author
/// naming a move they do not recommend.
const branchPliesHeader = 'BranchPlies';

/// The headers a line's id may be spelled in, none of which a sideline may
/// share with the game it came from.
const _idHeaders = {'LineID', 'LineId', 'Id', 'Line', 'Guid'};

/// [game]'s root-to-leaf paths as games of their own, in reading order: the
/// main line first, then each sideline where it branches, the way the
/// brackets nest. A game with no variations is kept as its own bytes.
List<String> _expanded(_Game game, _Grouping grouping) {
  final tree = game.read.tree!;
  if (!_hasVariation(tree)) return [game.text];
  final terminator = game.read.terminator ?? '*';
  final separator = game.read.separator.isEmpty ? '\n\n' : game.read.separator;
  return [
    for (final (index, path) in _leafPaths(tree).indexed)
      writeGameText(
        index == 0 ? game.read.tags : _sidelineTags(game, tree, path, grouping),
        _singleLine(tree, path),
        terminator: terminator,
        separator: separator,
      ),
  ];
}

bool _hasVariation(GameTree tree) {
  var siblings = tree.children;
  while (siblings.isNotEmpty) {
    if (siblings.length > 1) return true;
    siblings = siblings.first.children;
  }
  return false;
}

/// Every root-to-leaf path, first children first.
List<List<MoveNode>> _leafPaths(GameTree tree) {
  final paths = <List<MoveNode>>[];
  void walk(List<MoveNode> siblings, List<MoveNode> soFar) {
    if (siblings.isEmpty) {
      paths.add(soFar);
      return;
    }
    for (final child in siblings) {
      walk(child.children, [...soFar, child]);
    }
  }

  walk(tree.children, const []);
  return paths;
}

/// A tree whose only line is [path], each node keeping its comment and
/// glyphs. A comment that introduced a variation — written before its first
/// move — has nowhere to go once the brackets are gone but onto the move
/// before it, which is where a reader would put it anyway.
GameTree _singleLine(GameTree tree, List<MoveNode> path) {
  var rootComment = tree.rootComment;
  final nodes = <MoveNode>[];
  for (final node in path) {
    final starting = node.startingComment;
    if (starting != null) {
      if (nodes.isEmpty) {
        rootComment = _joined(rootComment, starting);
      } else {
        final previous = nodes.removeLast();
        nodes.add(
          MoveNode(
            san: previous.san,
            uci: previous.uci,
            fen: previous.fen,
            spelling: previous.spelling,
            comment: _joined(previous.comment, starting),
            nags: previous.nags,
          ),
        );
      }
    }
    nodes.add(
      MoveNode(
        san: node.san,
        uci: node.uci,
        fen: node.fen,
        spelling: node.spelling,
        comment: node.comment,
        nags: node.nags,
      ),
    );
  }
  var children = const <MoveNode>[];
  for (final node in nodes.reversed) {
    children = [node.copyWith(children: children)];
  }
  return GameTree(
    rootFen: tree.rootFen,
    rootComment: rootComment,
    children: children,
  );
}

String _joined(String? first, String second) =>
    first == null || first.trim().isEmpty ? second : '$first $second';

/// A sideline's headers: the game's own minus any line id, the naming
/// headers suffixed with the move where it last left the main line, and
/// [branchPliesHeader] recording every branch point.
List<PgnHeader> _sidelineTags(
  _Game game,
  GameTree tree,
  List<MoveNode> path,
  _Grouping grouping,
) {
  final branches = _branchPlies(tree, path);
  final label = _moveLabel(tree.rootFen, branches.last, path[branches.last]);
  final suffixed = {'Event', 'Opening', grouping.titleKey}
    ..remove(grouping.chapterKey);
  final tags = <PgnHeader>[];
  for (final header in game.read.tags) {
    if (header is! PgnTag) {
      tags.add(header);
      continue;
    }
    if (_idHeaders.contains(header.key)) continue;
    final value = header.value.trim();
    if (suffixed.contains(header.key) &&
        !isPlaceholderTitle(value)) {
      tags.add(PgnTag(header.key, '$value — $label', trailer: header.trailer));
      continue;
    }
    tags.add(header);
  }
  tags.add(PgnTag(branchPliesHeader, branches.join(' ')));
  return tags;
}

/// Every ply of [path] where it took a move other than its parent's first
/// child, counted from the game's start.
List<int> _branchPlies(GameTree tree, List<MoveNode> path) {
  final plies = <int>[];
  var siblings = tree.children;
  for (final (ply, node) in path.indexed) {
    if (!identical(siblings.first, node)) plies.add(ply);
    siblings = node.children;
  }
  return plies;
}

/// `5...Nf6`: the move at [ply] of a line from [root], as a person names it.
String _moveLabel(Fen root, int ply, MoveNode node) {
  final whiteMoves = root.whiteToMove ? ply.isEven : ply.isOdd;
  final number = root.fullMove + (ply + (root.whiteToMove ? 0 : 1)) ~/ 2;
  return whiteMoves ? '$number.${node.san}' : '$number...${node.san}';
}

/// Games gathered one per block, a blank line between them, a game that
/// repeats an earlier one's title and moves dropped: one course export
/// listed each of its lines under every one of its chapter titles.
final class _Lines {
  _Lines(this.titleKey);

  final String titleKey;
  final _out = StringBuffer();
  final _seen = <String>{};
  int count = 0;

  String get text => _out.toString();

  void keep(String game) {
    if (!_seen.add(_identity(game))) return;
    if (count > 0) _out.write('\n');
    _out
      ..write(game.trimRight())
      ..write('\n');
    count++;
  }

  String _identity(String game) {
    final title = RegExp(
      '^\\[$titleKey "([^"]*)"\\]',
      multiLine: true,
    ).firstMatch(game)?.group(1);
    final moves = game
        .replaceAll(RegExp(r'^\[[^\]]*\]\s*$', multiLine: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return '$title\u0000$moves';
  }
}
