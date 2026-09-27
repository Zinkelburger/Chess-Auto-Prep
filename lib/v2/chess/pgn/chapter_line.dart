import 'game_text.dart';
import 'game_tree.dart';
import 'pgn_issue.dart';

/// One game of a chapter file: the line a reader trains and a writer edits.
///
/// The game is the persistent unit, so a line keeps everything a write-back
/// needs — its tags in file order with the endings they had, its own tree
/// (variations included), the marker the file ended it with, the whitespace
/// before its moves and its verbatim source. An untouched line is written
/// back byte for byte; only an edited one is generated again.
final class ChapterLine {
  const ChapterLine({
    required this.tags,
    required this.tree,
    required this.text,
    required this.trailer,
    required this.terminator,
    required this.separator,
    this.issues = const [],
  });

  /// Every line of the game's header block, in file order.
  final List<PgnHeader> tags;

  /// The game's moves, or null when nothing could read it — a `[FEN]` header
  /// that is not a position. An unread game keeps [text] and is never merged,
  /// edited or generated again, so no edit elsewhere can write over it.
  final GameTree? tree;

  /// The game's source, with no trailing whitespace.
  final String text;

  /// The whitespace between this game and the next, kept so a file that is
  /// read and written again is unchanged.
  final String trailer;

  /// The game-termination marker the file wrote, or null when it wrote none.
  final String? terminator;

  /// The whitespace between the header block and the first move.
  final String separator;

  /// What reading the game could not carry into [tree].
  final List<PgnIssue> issues;

  /// The same game, separated from whatever follows it by [trailer].
  ///
  /// The whitespace between two games belongs to the place in the file, not
  /// to the game that happens to be there: a game moved to another place
  /// takes neither the blank line that followed it nor the missing newline
  /// at the end of the file.
  ChapterLine spacedBy(String trailer) => ChapterLine(
    tags: tags,
    tree: tree,
    text: text,
    trailer: trailer,
    terminator: terminator,
    separator: separator,
    issues: issues,
  );

  /// Whether [tree] holds everything [text] holds.
  ///
  /// Anything reading could not carry — a move that is not legal, a comment
  /// nobody closed, a `%` directive among the moves, a word that is not
  /// anything a game can hold — is one of [issues], and the text it stands
  /// for is still in the file. Generating the game again from [tree] would
  /// delete that text. A game that was not read whole is therefore written
  /// back as its own bytes and nothing else, and an edit that would have to
  /// rewrite it is refused instead.
  bool get isWhole => tree != null && issues.isEmpty;

  /// The identity every later lookup uses — training progress, rename,
  /// delete. Files in the wild spell it five ways; whichever one a file has
  /// is the line's id.
  String? get lineId {
    for (final key in const ['LineID', 'LineId', 'Id', 'Line', 'Guid']) {
      final value = tagValue(tags, key)?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// What a list calls the line at [index] of its file: its `Event`, where
  /// both apps write a line's name, else its place in the file.
  String nameAt(int index) {
    final event = tagValue(tags, 'Event')?.trim();
    return event == null || event.isEmpty ? 'Line ${index + 1}' : event;
  }
}

/// Whether [a] and [b] are the same games, one for one: what a chapter
/// built again around the same lines — another game of a file put on the
/// board — still is, though the list holding them is new.
bool sameLines(List<ChapterLine> a, List<ChapterLine> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!identical(a[i], b[i])) return false;
  }
  return true;
}
