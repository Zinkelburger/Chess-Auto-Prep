import '../pgn/chapter.dart';
import '../pgn/chapter_edit.dart';
import '../pgn/chapter_line.dart';
import '../pgn/game_text.dart';
import '../pgn/games_written.dart';
import '../pgn/pgn_reader.dart';
import 'analyzed_games.dart';
import 'mining.dart';

/// Adding mined puzzles to a tactics set, in exactly the text the old app
/// writes, so each app reads what the other mined.

/// One puzzle as its game in the set: the old app's headers in its order,
/// each written only when it says something, a blank line, then the note as
/// a comment before the answer.
///
/// ```
/// [Event "Default #1"]
/// [White "Tohirjonovich"]
/// [Black "BigManArkhangelsk"]
/// [Date "2026.08.21"]
/// [Result "*"]
/// [FEN "r1bq1rk1/pp2ppbp/2np1np1/2p5/2P1P1P1/2NPBN1P/PP3P2/R2QKB1R b KQ - 0 8"]
/// [SetUp "1"]
/// [GameId "chesscom_173321420294"]
/// [UserMove "h5"]
/// [MistakeType "?!"]
/// [OpponentBestResponse "Be2"]
/// [SolutionPv "a6 a4 Rb8 Bg2"]
/// [SourceMovetext "1. e4 c5 2. Nf3 g6 …"]
///
/// {h5 +0.6 → -0.1, a6 +0.6} 8... a6 *
/// ```
String puzzleText(MinedPuzzle puzzle, {required String event}) {
  final game = puzzle.game;
  final headers = StringBuffer();
  void tag(String key, String value, {bool always = false}) {
    if (always || value.isNotEmpty) {
      headers.writeln('[$key "${_escaped(value)}"]');
    }
  }

  tag('Event', event);
  tag('White', game.white, always: true);
  tag('Black', game.black, always: true);
  tag('Date', game.date);
  tag('Result', '*');
  tag('FEN', puzzle.fen.value);
  tag('SetUp', '1');
  tag('GameId', game.id);
  tag('UserMove', puzzle.played);
  tag('MistakeType', puzzle.kind.glyph);
  tag('OpponentBestResponse', puzzle.refutation);
  if (puzzle.engineLine.join(' ') != puzzle.answer.join(' ')) {
    tag('SolutionPv', puzzle.engineLine.join(' '));
  }
  tag('SourceMovetext', game.moves);
  final note = puzzle.note.trim().replaceAll('{', '(').replaceAll('}', ')');
  final moves = numberedSan(puzzle.fen, puzzle.answer);
  return '$headers\n{$note} $moves *';
}

String _escaped(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

/// [set] with [found] added at the end and its analysed-games line naming
/// [analyzed], which the caller has made the ids already there plus the
/// game just reviewed. The puzzles and the record that the game is done go
/// in one write, so a game is never marked done without its puzzles.
///
/// A puzzle is its position: one whose FEN the set already has is not
/// added again. Every game already in the file comes through as it was; the
/// edit declares the heading only because the analysed-games line is in it.
ChapterEdit withMined(
  Chapter set,
  List<MinedPuzzle> found, {
  required Set<String> analyzed,
}) {
  final fens = {for (final line in set.lines) ?tagValue(line.tags, 'FEN')};
  final added = <ChapterLine>[];
  for (final puzzle in found) {
    if (!fens.add(puzzle.fen.value)) continue;
    final number = set.lines.length + added.length + 1;
    final line = _lineOf(puzzleText(puzzle, event: '${set.name} #$number'));
    if (line == null) {
      return ChapterEditRefused(
        'the puzzle from ${puzzle.played} could not be read back',
      );
    }
    added.add(line);
  }
  final preamble = withAnalyzed(set.preamble, analyzed);
  if (added.isEmpty && preamble == set.preamble) {
    return const ChapterUnchanged();
  }
  final before = set.lines.length;
  final lines = [...set.lines, ...added];
  return ChapterEdited(
    withLines(set, _spaced(lines, before), preamble: preamble),
    GamesArranged(
      order: [for (var i = 0; i < before; i++) i, for (final _ in added) null],
      before: before,
      heading: preamble != set.preamble,
    ),
  );
}

/// The game [text] as a line of the set, or null when it does not read
/// back whole.
ChapterLine? _lineOf(String text) {
  final read = readGame(text);
  if (read.tree == null || !read.rewritable) return null;
  return ChapterLine(
    tags: read.tags,
    tree: read.tree,
    text: text,
    trailer: '\n',
    terminator: read.terminator,
    separator: read.separator,
  );
}

/// The old app's spacing for what was added: a blank line after every game
/// but the last, which ends the file with one newline. The games before
/// [kept] keep the space they had.
List<ChapterLine> _spaced(List<ChapterLine> lines, int kept) => [
  for (final (i, line) in lines.indexed)
    i < kept - 1 || lines.length == kept
        ? line
        : line.spacedBy(i == lines.length - 1 ? '\n' : '\n\n'),
];
