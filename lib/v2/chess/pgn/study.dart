import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
import 'chapter_line.dart';
import 'game_text.dart';

/// The Lichess study export format, which is what a study file in
/// `Documents/studies/` is: one `.pgn` holding one game per chapter.
///
/// Six tags belong to the study and are written again whenever the chapter
/// they describe is saved — `Event`, `StudyName`, `ChapterName`,
/// `Orientation`, and `FEN` with `SetUp` for a chapter that does not start
/// from the initial position. Every other tag a file carries is the file's,
/// and is written back exactly as it was read.

/// The tags this app writes for itself. A chapter's other tags — `Result`,
/// `ECO`, `Annotator`, whatever else a file brought — are never touched.
const studyOwnedTags = {
  'Event',
  'StudyName',
  'ChapterName',
  'Orientation',
  'FEN',
  'SetUp',
};

/// The token that marks where training starts asking. Training plays the
/// moves before it and asks for this one.
const quizStartMarker = 'tstart';

/// The token that marks where training stops asking.
const quizEndMarker = 'tend';

/// One chapter of a study: which game of the file it is, what it is called
/// and which way its board faces.
final class StudyChapter {
  const StudyChapter({
    required this.index,
    required this.name,
    required this.orientation,
  });

  /// The game's place in the file, counting from zero.
  final int index;

  final String name;

  /// The side the board faces when this chapter is open.
  final Side orientation;

  /// What the list shows before the name.
  int get ordinal => index + 1;
}

/// The name of the study itself: the `StudyName` tag of the first game that
/// has one, else the part of `Event` before the `: ` that Lichess puts the
/// chapter name after, else null.
///
/// A file's own name is what the user sees in the list; this is the name the
/// tags claim, which is what a chapter written again has to repeat.
String? studyNameIn(List<ChapterLine> lines) {
  for (final line in lines) {
    final named = tagValue(line.tags, 'StudyName')?.trim();
    if (named != null && named.isNotEmpty) return named;
  }
  for (final line in lines) {
    final event = tagValue(line.tags, 'Event')?.trim() ?? '';
    final split = event.indexOf(': ');
    if (split > 0) return event.substring(0, split);
  }
  return null;
}

/// What the chapter at [index] is called: `ChapterName`, else `Event` with
/// the study's own name peeled off the front, else the players, else
/// `Chapter N`. The old app reads it in that order and so does Lichess.
String studyChapterName(ChapterLine line, {required int index, String? study}) {
  final named = tagValue(line.tags, 'ChapterName')?.trim();
  if (named != null && named.isNotEmpty) return named;
  final event = tagValue(line.tags, 'Event')?.trim() ?? '';
  final peeled = _withoutStudyPrefix(event, study);
  // `?` is what a PGN writes where it knows no name; it is not one.
  if (peeled.isNotEmpty && peeled != '?') return peeled;
  final white = tagValue(line.tags, 'White')?.trim() ?? '';
  final black = tagValue(line.tags, 'Black')?.trim() ?? '';
  if (white.isNotEmpty && black.isNotEmpty) return '$white - $black';
  return 'Chapter ${index + 1}';
}

String _withoutStudyPrefix(String event, String? study) {
  final split = event.indexOf(': ');
  if (split <= 0 || split + 2 >= event.length) return event;
  final head = event.substring(0, split);
  if (study != null && head != study) return event;
  return event.substring(split + 2).trim();
}

/// Which way the board faces in this chapter: the `Orientation` tag, else
/// the side to move in a set-up position, else White. A study written
/// somewhere else may have no tag at all, and a Black problem set up from a
/// FEN should not open upside down.
Side studyOrientation(ChapterLine line) {
  final tag = tagValue(line.tags, 'Orientation')?.trim().toLowerCase();
  if (tag == 'black') return Side.black;
  if (tag == 'white') return Side.white;
  final fen = tagValue(line.tags, 'FEN');
  if (fen == null) return Side.white;
  return Fen(fen).whiteToMove ? Side.white : Side.black;
}

/// Every chapter of [lines], in file order.
List<StudyChapter> studyChapters(List<ChapterLine> lines) {
  final study = studyNameIn(lines);
  return [
    for (final (index, line) in lines.indexed)
      StudyChapter(
        index: index,
        name: studyChapterName(line, index: index, study: study),
        orientation: studyOrientation(line),
      ),
  ];
}

/// [tags] with the study's own six replaced by what this study says now, and
/// every other tag of the file kept where it was.
///
/// A tag the file already has is replaced in place, so a chapter written
/// again does not have its headers reshuffled; one it does not have is added
/// at the end of the block, before whatever unparsed lines were in it.
List<PgnHeader> withStudyTags(
  List<PgnHeader> tags, {
  required String study,
  required String chapter,
  required Side orientation,
  required Fen root,
  String ending = '\n',
}) {
  final wanted = _studyTags(
    study: study,
    chapter: chapter,
    orientation: orientation,
    root: root,
  );
  final out = <PgnHeader>[];
  final placed = <String>{};
  for (final line in tags) {
    if (line is! PgnTag || !studyOwnedTags.contains(line.key)) {
      out.add(line);
      continue;
    }
    final replacement = wanted[line.key];
    // A tag this study has nothing to say about — `[FEN]` on a chapter that
    // starts from the initial position — is the file's, and stays.
    if (replacement == null) {
      out.add(line);
      continue;
    }
    placed.add(line.key);
    out.add(PgnTag(line.key, replacement, trailer: line.trailer));
  }
  final trailer = tags.isEmpty ? ending : tags.first.trailer;
  for (final MapEntry(:key, :value) in wanted.entries) {
    if (!placed.contains(key)) out.add(PgnTag(key, value, trailer: trailer));
  }
  return List.unmodifiable(out);
}

Map<String, String> _studyTags({
  required String study,
  required String chapter,
  required Side orientation,
  required Fen root,
}) => {
  'Event': '$study: $chapter',
  'StudyName': study,
  'ChapterName': chapter,
  'Orientation': orientation == Side.black ? 'black' : 'white',
  if (root != Fen.initial) ...{'FEN': root.value, 'SetUp': '1'},
};

/// One chapter as a whole game, for a study being made or a chapter added to
/// one. `*` is the marker a game nobody finished carries.
String newStudyChapterText({
  required String study,
  required String chapter,
  required Side orientation,
  Fen root = Fen.initial,
  String ending = '\n',
}) {
  final tags = withStudyTags(
    const [],
    study: study,
    chapter: chapter,
    orientation: orientation,
    root: root,
    ending: ending,
  );
  final buffer = StringBuffer();
  for (final tag in tags) {
    buffer
      ..write(tag.text)
      ..write(tag.trailer);
  }
  return (buffer..write('$ending*')).toString();
}

/// A study file with one empty chapter in it, which is what a new study is.
String newStudyText({required String study, required String chapter}) =>
    '${newStudyChapterText(study: study, chapter: chapter, orientation: Side.white)}\n';

/// What to call a chapter the user did not name: `Chapter N`, where N is one
/// past however many the study already has, skipping names it is using.
String nextChapterName(List<StudyChapter> chapters) {
  final taken = {for (final chapter in chapters) chapter.name};
  var n = chapters.length + 1;
  while (taken.contains('Chapter $n')) {
    n++;
  }
  return 'Chapter $n';
}
