import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
import 'chapter.dart';
import 'chapter_line.dart';
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

sealed class StudyEdit {
  const StudyEdit();
}

/// The study now holds [chapter], having written the games [written] names.

final class ChapterWritten extends StudyEdit {
  const ChapterWritten(this.chapter, {required this.written});

  final Chapter chapter;
  final GamesWritten written;
}

/// The study now holds [chapter], whose games are the ones it had, in the
/// order [from] gives and byte for byte as they were. Reordering and
/// deleting a chapter are the only edits that do this.
final class ChaptersReordered extends StudyEdit {
  const ChaptersReordered(this.chapter, {required this.from});

  final Chapter chapter;

  /// For each game the file will hold, where it is in the file now.
  final List<int> from;
}

/// Nothing changed. [reason] is one plain English sentence for the screen.
final class ChapterEditRefused extends StudyEdit {
  const ChapterEditRefused(this.reason);

  final String reason;
}

/// A new chapter at the end of the study, which is what the file's game
/// order means by last, and the focus moved onto it.
StudyEdit addChapter(
  Chapter chapter, {
  required String study,
  required String name,
  required Side orientation,
  Fen root = Fen.initial,
}) {
  final text = newStudyChapterText(
    study: study,
    chapter: name,
    orientation: orientation,
    root: root,
  );
  final read = readGame(text);
  if (read.issues.isNotEmpty || read.tree == null) {
    return ChapterEditRefused(
      'That starting position cannot be written as a chapter: '
      '${read.issues.firstOrNull?.detail ?? 'it is not a position'}.',
    );
  }
  final lines = _separated([
    ...chapter.lines,
    ChapterLine(
      tags: read.tags,
      tree: read.tree,
      text: text,
      trailer: '\n',
      terminator: read.terminator,
      separator: read.separator,
    ),
  ]);
  return ChapterWritten(
    withLines(chapter, lines, game: lines.length - 1),
    written: GamesWritten(appended: 1),
  );
}

/// The chapter at [index] under another name, with the study's own tags
/// written again and every other tag of that game kept.
StudyEdit renameChapter(
  Chapter chapter, {
  required String study,
  required int index,
  required String name,
}) => _retagged(chapter, study: study, index: index, name: name);

/// The chapter at [index] facing [orientation]. The board turns with it when
/// it is the chapter on screen, because the board faces [Chapter.side] and
/// that is read from this tag.
StudyEdit setChapterOrientation(
  Chapter chapter, {
  required String study,
  required int index,
  required Side orientation,
}) => _retagged(chapter, study: study, index: index, orientation: orientation);

/// The chapter at [index] moved [by] places, one at a time through the row
/// menu. A move past either end changes nothing.
StudyEdit moveChapter(Chapter chapter, {required int index, required int by}) {
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
  return _inOrder(chapter, order, focus: to);
}

/// The study without the chapter at [index]. The last chapter stays: a study
/// with no chapters is a file with no games, which nothing could open again.
StudyEdit deleteChapter(Chapter chapter, {required int index}) {
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
  return _inOrder(chapter, order, focus: index.clamp(0, order.length - 1));
}

/// The chapter at [index] with the study's six tags written again from what
/// it says now, [name] and [orientation] overriding what the file holds.
StudyEdit _retagged(
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
  return ChapterWritten(
    withLines(chapter, lines),
    written: GamesWritten(rewritten: {index}),
  );
}

/// The study holding its games in [order], each byte for byte as it is now,
/// with the focus on the game at [focus] of the new order.
StudyEdit _inOrder(Chapter chapter, List<int> order, {required int focus}) {
  final lines = _separated([for (final from in order) chapter.lines[from]]);
  return ChaptersReordered(
    withLines(chapter, lines, game: focus),
    from: List.unmodifiable(order),
  );
}

/// [lines] with a blank line between the games and one newline after the
/// last, so every game still starts its own `[Event ` line once they have
/// been put in another order.
///
/// Only the whitespace between games changes; no game's own bytes are
/// touched, which is what lets a reorder be declared as one.
List<ChapterLine> _separated(List<ChapterLine> lines) => [
  for (final (index, line) in lines.indexed)
    _withTrailer(line, index == lines.length - 1 ? '\n' : '\n\n'),
];

ChapterLine _withTrailer(ChapterLine line, String trailer) =>
    line.trailer == trailer
    ? line
    : ChapterLine(
        tags: line.tags,
        tree: line.tree,
        text: line.text,
        trailer: trailer,
        terminator: line.terminator,
        separator: line.separator,
        issues: line.issues,
      );

bool _holds(Chapter chapter, int index) =>
    index >= 0 && index < chapter.lines.length;
