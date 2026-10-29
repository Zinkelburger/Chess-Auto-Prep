import 'chapter_line.dart';
import 'game_text.dart';
import 'move_text.dart';
import 'study.dart';

/// A study's chapters as Lichess takes them.
///
/// Lichess keeps only some tags of an imported chapter and refuses any other
/// name through its tag API, so a chapter is sent with those alone. The
/// `Event` this app writes for itself, `Study: Chapter`, is not the game's
/// and stays behind; an event the player typed goes with the game. A
/// chapter that came from Lichess, or was sent there, names its Lichess
/// chapter in `ChapterURL`, as Lichess's own export does.

/// The tags Lichess keeps on a study chapter, in the order it lists them.
const lichessChapterTags = [
  'White',
  'WhiteElo',
  'WhiteTitle',
  'WhiteTeam',
  'WhiteFideId',
  'Black',
  'BlackElo',
  'BlackTitle',
  'BlackTeam',
  'BlackFideId',
  'TimeControl',
  'Date',
  'Result',
  'Termination',
  'Site',
  'Event',
  'Round',
  'Board',
  'Annotator',
  'GameId',
  'WhiteCountry',
  'BlackCountry',
];

/// Where a chapter of Lichess's lives, the tag its export writes.
const chapterUrlTag = 'ChapterURL';

/// The tags of [line] Lichess keeps, with the values the chapter has. A
/// value Lichess would drop (empty, `?`) is left out, as is the `Event` the
/// study wrote for itself.
Map<String, String> lichessTagsOf(ChapterLine line) {
  final study = studyNameIn([line]);
  return {
    for (final key in lichessChapterTags)
      if (tagValue(line.tags, key)?.trim() case final value?
          when value.isNotEmpty &&
              value != '?' &&
              !(key == 'Event' &&
                  study != null &&
                  !ownEvent(value, study: study)))
        key: value,
  };
}

/// [line] as one chapter's PGN for Lichess: the tags it keeps, the starting
/// position when it is not the usual one, and every move, comment, glyph and
/// shape. Null when the chapter could not be read whole.
String? lichessChapterPgn(ChapterLine line) {
  final tree = line.tree;
  if (tree == null || !line.isWhole) return null;
  final tags = lichessTagsOf(line);
  final custom = tagValue(line.tags, 'FEN');
  final buffer = StringBuffer();
  for (final MapEntry(:key, :value) in tags.entries) {
    buffer.writeln(PgnTag(key, value).text);
  }
  if (custom != null && custom.trim().isNotEmpty) {
    buffer
      ..writeln(PgnTag('FEN', tree.rootFen.value).text)
      ..writeln(const PgnTag('SetUp', '1').text);
  }
  buffer
    ..writeln()
    ..writeln(writeMoveText(tree, terminator: line.terminator ?? '*'));
  return buffer.toString();
}
