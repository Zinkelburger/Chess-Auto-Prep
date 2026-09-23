/// Chapters named by a tag rather than by a file.
///
/// A course is one PGN: a Chessable export, a Lichess study, a repertoire
/// imported whole. Each game says which chapter it belongs to in its own
/// `[ChapterName]` tag — the Lichess study export's tag — so a game belongs
/// to its chapter wherever it sits in the file, and moving a line to another
/// chapter is one tag in one file rather than two saves to two files.
///
/// A file holds several chapters only when its games name at least two:
/// one chapter per name, plus one named after the file for the games that
/// name none. Any other file is one chapter, named after the file, exactly
/// as before — including a chapter file an earlier import wrote, whose games
/// all still carry the study chapter's name.
///
/// A chapter of a tagged file opens as a [SectionView]: its games, taken out
/// of the file in file order, as a [Chapter] like any other, so every edit
/// works on it unchanged. What an edit makes of the view is put back into the
/// file by [spliced], which says in the file's own places what the edit did,
/// and the store's checks then hold for the whole file exactly as they do for
/// a chapter file.
library;

import 'chapter.dart';
import 'chapter_edit.dart';
import 'chapter_line.dart';
import 'game_text.dart';
import 'games_written.dart';
import 'line_id_pins.dart';
import 'pgn_lexer.dart';
import 'pgn_reader.dart';
import 'pgn_token.dart';

/// The tag a game names its chapter in.
const chapterNameTag = 'ChapterName';

/// The chapter [line] names, or null when it names none.
String? sectionOf(ChapterLine line) {
  final name = tagValue(line.tags, chapterNameTag)?.trim();
  return name == null || name.isEmpty ? null : name;
}

/// The names [lines] carry, in the order they first appear, with null for
/// the games that name none — present only when there are such games.
List<String?> sectionsIn(Iterable<ChapterLine> lines) {
  final seen = <String?>{};
  return [
    for (final line in lines)
      if (seen.add(sectionOf(line))) sectionOf(line),
  ];
}

/// The chapters of a file whose games are [lines]: [sectionsIn] when they
/// name two or more, else the one chapter that is the whole file (null).
List<String?> chapterSections(Iterable<ChapterLine> lines) {
  final names = sectionsIn(lines);
  return names.length < 2 ? const [null] : names;
}

/// The chapter names a file's text carries, read off its header lines
/// without parsing a move: what a library listing needs, for a file of
/// thousands of games. The same answer as [chapterSections]: in
/// first-appearance order, null standing for the games with no name, and
/// just `[null]` for a file of one chapter.
List<String?> sectionsInText(String text) {
  final found = <String?>[];
  final seen = <String?>{};
  var named = false;
  for (final game in splitChapterText(text).games) {
    final section = _sectionNamedIn(game.text);
    if (section != null) named = true;
    if (seen.add(section)) found.add(section);
  }
  if (found.length < 2 || !named) return const [null];
  return found;
}

/// The chapter the game [text] names, read as [sectionOf] reads it: from
/// the tags the lexer finds in its header block, where two tags can share a
/// line and a value ends at the first quote no backslash escapes. A listing
/// that read the lines some other way would name chapters the file does not
/// open as.
String? _sectionNamedIn(String text) {
  for (final token in lexHeader(text)) {
    if (token is! TagToken || token.key != chapterNameTag) continue;
    final name = token.value.trim();
    return name.isEmpty ? null : name;
  }
  return null;
}

/// An edit of a file ready to write: the file after it, what it did to the
/// file's games, and the chapter of it to show.
typedef FileEdit = ({Chapter file, GamesArranged games, SectionView shown});

/// [edited], an edit of the whole of [file] placed by [games], with the ids
/// it would change pinned ([withIdsPinned]), showing [section] — or the
/// file's first chapter, when the edit left none of that one's games.
FileEdit fileEdit(
  Chapter file,
  Chapter edited,
  GamesArranged games,
  String? section,
) {
  final pinned = withIdsPinned(file, edited, games);
  return (
    file: pinned.chapter,
    games: pinned.games,
    shown: sectionView(pinned.chapter, sectionAfter(pinned.chapter, section)),
  );
}

/// [section] when [file] still has that chapter; otherwise its first — an
/// edit took the last of the chapter's games, or left the file one chapter,
/// and what is shown must be a chapter the library lists.
String? sectionAfter(Chapter file, String? section) {
  final sections = chapterSections(file.lines);
  return sections.contains(section) ? section : sections.first;
}

/// One chapter of a file: the file, the chapter's name in it and where its
/// games sit.
final class SectionView {
  const SectionView({
    required this.file,
    required this.section,
    required this.places,
    required this.chapter,
    this.stamp,
  });

  /// The whole file as a chapter.
  final Chapter file;

  /// Which chapter of the file this is: the name its games carry, or null
  /// for the games that carry none — every game, in a file of one chapter.
  final String? section;

  /// The name a game added to the chapter carries: [section], or in a file
  /// of one chapter whose games all carry one name, that name, so a line
  /// added there does not split the file in two.
  final String? stamp;

  /// For each game of [chapter], its index among the file's games.
  final List<int> places;

  /// The chapter's games as a chapter of their own, carrying the ids the
  /// file trains them under ([Chapter.lineIds]): a game's id depends on its
  /// place in the file, not in the chapter.
  final Chapter chapter;

  /// Whether the chapter is the whole file and names no chapter, so an edit
  /// to it is an edit to the file and nothing has to be put back: a game it
  /// adds needs no name.
  bool get isWholeFile => stamp == null && places.length == file.lines.length;

  /// Where the chapter's games at [games] sit among the file's games.
  Set<int> placesOf(Set<int> games) => {
    for (final game in games)
      if (game >= 0 && game < places.length) places[game],
  };
}

/// The chapter [section] of [file] when it is one of several the file holds
/// by name; null when it is the whole file, which is every file whose games
/// name no chapter.
SectionView? partOf(Chapter file, String? section) {
  final view = sectionView(file, section);
  return view.isWholeFile ? null : view;
}

/// The chapter [section] of [file], called by its name — or, for the games
/// that name none, by the file's ([Chapter.name] of [file]).
SectionView sectionView(Chapter file, String? section) {
  final whole = chapterSections(file.lines).length < 2;
  final places = [
    for (final (index, line) in file.lines.indexed)
      if (whole || sectionOf(line) == section) index,
  ];
  final names = sectionsIn(file.lines);
  final ids = trainedIds(file.lines);
  final chapter = withLines(file, [for (final at in places) file.lines[at]]);
  return SectionView(
    file: file,
    section: section,
    places: List.unmodifiable(places),
    stamp: whole ? (names.length == 1 ? names.single : null) : section,
    chapter: withLineIds(renamedChapter(chapter, section ?? file.name), [
      for (final at in places) ids[at],
    ]),
  );
}

/// [edited], an edit of [view]'s chapter placed by [games], put back into
/// the file: the file after the edit, and what the edit did to the file's
/// games.
///
/// The chapter's games go back into the places they came from, in the order
/// the edit left them; a place the edit emptied is gone, and a game the edit
/// added goes at the end of the file carrying the chapter's name. Every
/// other game of the file keeps its place and its bytes.
///
/// A game the edit added also gets an id no game of the file is known by
/// ([withFreeId]): the edit could only see its own chapter's ids, and a game
/// of another chapter may already be trained under the one it chose.
///
/// Null when a game the edit added cannot be given the chapter's name or an
/// id of its own.
({Chapter file, GamesArranged games})? spliced(
  SectionView view,
  Chapter edited,
  GamesArranged games,
) {
  final file = view.file;
  final slots = view.places.toSet();
  final order = <int?>[];
  final lines = <ChapterLine>[];
  var next = 0;
  Set<String>? taken;
  ChapterLine? named(int at) {
    final line = edited.lines[at];
    if (games.order[at] != null) return line;
    final stamped = sectionOf(line) == view.stamp
        ? line
        : withSection(line, view.stamp);
    if (stamped == null) return null;
    return withFreeId(stamped, lines.length, taken ??= idsInUse(file));
  }

  void add(int at) {
    final line = named(at);
    if (line == null) throw const _Unnamed();
    final from = games.order[at];
    order.add(from == null ? null : view.places[from]);
    lines.add(line);
  }

  // An edit that kept the chapter's games in their order — a line edited,
  // deleted, added — leaves each of them in its own place. One that
  // reordered them fills the chapter's places in its new order.
  final kept = games.order.nonNulls.toList();
  final inOrder = [
    for (var i = 1; i < kept.length; i++) kept[i - 1] < kept[i],
  ].every((ascending) => ascending);
  final at = {
    for (final (index, from) in games.order.indexed)
      if (from != null) view.places[from]: index,
  };
  try {
    for (var place = 0; place < file.lines.length; place++) {
      if (!slots.contains(place)) {
        order.add(place);
        lines.add(file.lines[place]);
      } else if (inOrder) {
        if (at[place] case final index?) add(index);
      } else {
        while (next < edited.lines.length && games.order[next] == null) {
          next++;
        }
        if (next < edited.lines.length) add(next++);
      }
    }
    for (final (index, from) in games.order.indexed) {
      if (from == null) add(index);
    }
  } on _Unnamed {
    return null;
  }
  final after = withLines(
    file,
    _spaced(file, lines),
    preamble: games.heading ? edited.preamble : null,
  );
  return (
    file: after,
    games: GamesArranged(
      order: order,
      rewritten: {for (final at in games.rewritten) view.places[at]},
      before: file.lines.length,
      heading: games.heading,
    ),
  );
}

/// [lines] separated the way [file] separated its places, a place past its
/// end by a blank line, and the last by what the file ended with.
List<ChapterLine> _spaced(Chapter file, List<ChapterLine> lines) {
  final was = file.lines;
  final ending = was.isEmpty ? '\n' : was.last.trailer;
  return [
    for (final (index, line) in lines.indexed)
      line.spacedBy(
        index == lines.length - 1
            ? ending
            : index < was.length - 1
            ? was[index].trailer
            : '\n\n',
      ),
  ];
}

/// [line] naming [section] as its chapter — or naming none when it is
/// null — with its moves' text untouched. Null when the tag would not read
/// back.
ChapterLine? withSection(ChapterLine line, String? section) {
  final at = line.tags.indexWhere(
    (header) => header is PgnTag && header.key == chapterNameTag,
  );
  final List<PgnHeader> tags;
  if (section == null) {
    if (at < 0) return line;
    tags = [...line.tags]..removeAt(at);
  } else if (at < 0) {
    final last = line.tags.isEmpty ? null : line.tags.last;
    tags = [
      ...line.tags,
      PgnTag(chapterNameTag, section, trailer: last?.trailer ?? '\n'),
    ];
  } else {
    final was = line.tags[at] as PgnTag;
    tags = [...line.tags]
      ..[at] = PgnTag(chapterNameTag, section, trailer: was.trailer);
  }
  final written = withHeaders(line, tags);
  final back = readGame(written.text);
  final name = tagValue(back.tags, chapterNameTag)?.trim();
  final read = name == null || name.isEmpty ? null : name;
  return read == section ? written : null;
}

final class _Unnamed implements Exception {
  const _Unnamed();
}

/// [file] with the games at [places] naming [section] as their chapter:
/// what moving lines to another chapter of the same file is. Each game keeps
/// its place and its moves' bytes; only the one tag changes.
ChapterEdit linesNamed(Chapter file, Set<int> places, String? section) {
  final lines = [...file.lines];
  final rewritten = <int>{};
  for (final at in places) {
    if (at < 0 || at >= lines.length) continue;
    if (sectionOf(lines[at]) == section) continue;
    final named = withSection(lines[at], section);
    if (named == null) return const ChapterEditRefused(_unnamedReason);
    lines[at] = named;
    rewritten.add(at);
  }
  if (rewritten.isEmpty) return const ChapterUnchanged();
  return ChapterEdited(
    withLines(file, lines),
    GamesArranged.of(
      GamesWritten(rewritten: rewritten),
      before: file.lines.length,
    ),
  );
}

/// [file] with the chapter [from] called [to]: every game that names it
/// names the new name. Refused when [to] is already a chapter of the file,
/// which would fold two chapters into one.
ChapterEdit sectionRenamed(Chapter file, String? from, String to) {
  final name = to.trim();
  if (name.isEmpty) return const ChapterEditRefused('a chapter needs a name');
  if (name != from && sectionsIn(file.lines).contains(name)) {
    return const ChapterEditRefused('that chapter already exists');
  }
  return linesNamed(file, {
    for (final (index, line) in file.lines.indexed)
      if (sectionOf(line) == from) index,
  }, name);
}

/// [file] without the games of the chapter [section]. The file's other
/// chapters keep their places and their bytes; taking it back is undo.
ChapterEdit sectionRemoved(Chapter file, String? section) {
  final order = [
    for (final (index, line) in file.lines.indexed)
      if (sectionOf(line) != section) index,
  ];
  if (order.length == file.lines.length) return const ChapterUnchanged();
  return ChapterEdited(
    withLines(file, _spaced(file, [for (final at in order) file.lines[at]])),
    GamesArranged(order: order, before: file.lines.length),
  );
}

const _unnamedReason = 'a line could not be given its chapter name';
