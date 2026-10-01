import 'game_text.dart';
import 'game_tree.dart';
import 'pgn_issue.dart';
import 'pgn_reader.dart';

/// One game of a chapter file: the line a reader trains and a writer edits.
///
/// The game is the persistent unit, so a line keeps everything a write-back
/// needs — its tags in file order with the endings they had, its own tree
/// (variations included), the marker the file ended it with, the whitespace
/// before its moves and its verbatim source. An untouched line is written
/// back byte for byte; only an edited one is generated again.
final class ChapterLine {
  ChapterLine({
    required this.tags,
    required GameTree? tree,
    required this.text,
    required this.trailer,
    required String? terminator,
    required String separator,
    List<PgnIssue> issues = const [],
  }) : _read = (
         tree: tree,
         terminator: terminator,
         separator: separator,
         issues: issues,
       );

  /// The game [text] with its moves not read yet: [tags] is its header
  /// block ([readHeaders]), and everything below the header — [tree],
  /// [terminator], [separator], [issues] — is read from [text] the first
  /// time one of them is asked for, or handed over by [take].
  ///
  /// A file of thousands of games is listed from its headers and shows one
  /// game at a time, so it opens without replaying every move of every game
  /// first. What a line answers is the same either way; only when the work
  /// is done differs.
  ChapterLine.unread({
    required this.tags,
    required this.text,
    required this.trailer,
  });

  ChapterLine._(this.tags, this.text, this.trailer, this._read);

  /// Every line of the game's header block, in file order.
  final List<PgnHeader> tags;

  /// The game's source, with no trailing whitespace.
  final String text;

  /// The whitespace between this game and the next, kept so a file that is
  /// read and written again is unchanged.
  final String trailer;

  /// What is below the header, once read. Set once and never changed.
  _Moves? _read;

  _Moves get _moves => _read ??= _movesOf(readGame(text));

  /// Whether the moves are in hand, so that asking for them costs nothing.
  bool get isRead => _read != null;

  /// Takes [read], which is [readGame] of [text] done somewhere else, so the
  /// moves need not be read here. A line that has its moves keeps them: both
  /// are the same reading of the same text, and whoever holds the first
  /// tree goes on holding the line's tree.
  void take(GameRead read) => _read ??= _movesOf(read);

  /// The game's moves, or null when nothing could read it — a `[FEN]` header
  /// that is not a position. An unread game keeps [text] and is never merged,
  /// edited or generated again, so no edit elsewhere can write over it.
  GameTree? get tree => _moves.tree;

  /// The game-termination marker the file wrote, or null when it wrote none.
  String? get terminator => _moves.terminator;

  /// The whitespace between the header block and the first move.
  String get separator => _moves.separator;

  /// What reading the game could not carry into [tree].
  List<PgnIssue> get issues => _moves.issues;

  /// The same game, separated from whatever follows it by [trailer].
  ///
  /// The whitespace between two games belongs to the place in the file, not
  /// to the game that happens to be there: a game moved to another place
  /// takes neither the blank line that followed it nor the missing newline
  /// at the end of the file.
  ChapterLine spacedBy(String trailer) =>
      ChapterLine._(tags, text, trailer, _read);

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
  /// is the line's id ([idHeaderAt]).
  String? get lineId {
    final at = idHeaderAt(tags);
    return at < 0 ? null : (tags[at] as PgnTag).value.trim();
  }

  /// What a list calls the line at [index] of its file: its `Event`, where
  /// both apps write a line's name, else its place in the file.
  String nameAt(int index) {
    final event = tagValue(tags, 'Event')?.trim();
    return event == null || event.isEmpty ? 'Line ${index + 1}' : event;
  }
}

/// What a game holds below its header block.
typedef _Moves = ({
  GameTree? tree,
  String? terminator,
  String separator,
  List<PgnIssue> issues,
});

/// [read] without its tags, which the line holds itself.
_Moves _movesOf(GameRead read) => (
  tree: read.tree,
  terminator: read.terminator,
  separator: read.separator,
  issues: read.issues,
);

/// Where in [tags] the header a game's id comes from is, or -1 for none.
///
/// The keys are tried in the order files in the wild are known to use them,
/// and under each the last tag wins, as it does in the old app, which reads
/// a game's headers into a map: both apps key one set of progress files by
/// this id. A key whose last tag is blank gives way to the next key.
int idHeaderAt(List<PgnHeader> tags) {
  for (final key in const ['LineID', 'LineId', 'Id', 'Line', 'Guid']) {
    final at = tags.lastIndexWhere((tag) => tag is PgnTag && tag.key == key);
    if (at >= 0 && (tags[at] as PgnTag).value.trim().isNotEmpty) return at;
  }
  return -1;
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
