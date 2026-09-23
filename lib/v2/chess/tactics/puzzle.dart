import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
import '../pgn/chapter_line.dart';
import '../pgn/comment_text.dart';
import '../pgn/game_text.dart';

/// How bad the move a puzzle was mined from was. The old app's review marks
/// a move `?!`, `?` or `??` when it drops the mover's winning chance by 0.1,
/// 0.2 or 0.3; a puzzle with no `MistakeType` header was written by hand or
/// imported, and is custom.
enum MistakeKind {
  blunder('??', 'blunder', 'blunders'),
  mistake('?', 'mistake', 'mistakes'),
  inaccuracy('?!', 'inaccuracy', 'inaccuracies'),
  custom('', 'custom', 'custom');

  const MistakeKind(this.glyph, this.word, this.plural);

  /// What the file's `MistakeType` header holds.
  final String glyph;

  /// What a person calls one, and more than one.
  final String word;
  final String plural;

  static MistakeKind of(String? glyph) => switch (glyph?.trim()) {
    '??' => blunder,
    '?' => mistake,
    '?!' => inaccuracy,
    _ => custom,
  };
}

/// How a puzzle has gone so far, from the headers the old app writes after
/// each attempt; its `HintsUsed` is kept in the file and not read, as this
/// app gives no hints. Zero reviews means never tried.
final class PuzzleStats {
  const PuzzleStats({
    this.reviews = 0,
    this.successes = 0,
    this.lastReviewed,
    this.seconds,
    this.stars = 0,
  });

  final int reviews;
  final int successes;

  /// When it was last tried, in local time.
  final DateTime? lastReviewed;

  /// How long the last attempt took, not an average.
  final double? seconds;

  /// 1 to 5, or 0 when unrated. One star means "hide this puzzle".
  final int stars;

  bool get isNew => reviews == 0;

  /// The share of attempts solved; 0 for a puzzle never tried, so a new
  /// puzzle sorts with the ones always failed.
  double get successRate => reviews == 0 ? 0 : successes / reviews;
}

/// The note a mined puzzle carries before its first move:
/// `h5 +0.6 → -0.1, a6 +0.6` — the move played, the evaluation before and
/// after it, then the better move and its evaluation. Both numbers are from
/// the side to move's point of view, in pawns or `#N` for a mate.
final class PuzzleNote {
  const PuzzleNote({
    required this.played,
    required this.before,
    required this.after,
  });

  final String played;
  final String before;
  final String after;

  static final _shape = RegExp(r'^(\S+)\s+(\S+)\s+→\s+(\S+?),');

  /// The note in [comment], or null when it is not in this shape.
  static PuzzleNote? parse(String? comment) {
    final match = _shape.firstMatch(displayComment(comment ?? '').trim());
    if (match == null) return null;
    return PuzzleNote(played: match[1]!, before: match[2]!, after: match[3]!);
  }
}

/// One puzzle of a tactics set: a game of the set's file whose `[FEN]` is
/// the position to solve and whose main line is the answer. The side to move
/// is the solver; even plies of [answer] are theirs and odd plies are the
/// opponent's replies.
final class Puzzle {
  const Puzzle({
    required this.index,
    required this.fen,
    required this.answer,
    required this.kind,
    required this.stats,
    this.played,
    this.refutation,
    this.white = '',
    this.black = '',
    this.date = '',
    this.gameId = '',
    this.note,
  });

  /// Which game of the file it is, counting from zero.
  final int index;

  final Fen fen;

  /// The answer's moves as SAN, the solver's first.
  final List<String> answer;

  final MistakeKind kind;
  final PuzzleStats stats;

  /// The move the user played in the game, as SAN; null for a custom one.
  final String? played;

  /// How the opponent punishes [played].
  final String? refutation;

  final String white;
  final String black;

  /// The game's date as PGN writes it, `2026.08.21`.
  final String date;

  /// The game it was mined from, as the review names it:
  /// `chesscom_173321420294`, `lichess_AbCd1234`.
  final String gameId;

  final PuzzleNote? note;

  Side get toMove => fen.whiteToMove ? Side.white : Side.black;

  /// How many moves the solver has to find.
  int get movesToFind => (answer.length + 1) ~/ 2;

  /// The day the game was played, or null when the header does not say.
  DateTime? get playedOn {
    final parts = date.split('.');
    if (parts.length != 3) return null;
    final (y, m, d) = (
      int.tryParse(parts[0]),
      int.tryParse(parts[1]),
      int.tryParse(parts[2]),
    );
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  /// The move number of the position, as a reader counts it.
  int get moveNumber => fen.fullMove;

  /// The player the solver faced.
  String get opponent => toMove == Side.white ? black : white;

  /// Whether [query] names this puzzle's players, date or move played, as
  /// the list's search box reads it; every word must match somewhere.
  bool matches(String query) {
    final haystack = '$white $black $date ${played ?? ''}'.toLowerCase();
    return query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .every(haystack.contains);
  }

  /// `23... Nxe5??` — the move played, numbered from the position, with its
  /// glyph; for a custom puzzle, just the side to move.
  String get label {
    final side = toMove == Side.white;
    final move = played;
    if (move == null) return '${side ? 'White' : 'Black'} to play';
    final dots = side ? '.' : '...';
    return '$moveNumber$dots $move${kind.glyph}';
  }
}

/// The puzzle game [line] at [index] of its file holds, or null when it is
/// not one: no position it could be read from, or no answer to find.
Puzzle? puzzleOf(ChapterLine line, int index) {
  final tree = line.tree;
  if (tree == null || tree.children.isEmpty) return null;
  final answer = <String>[];
  for (var nodes = tree.children; nodes.isNotEmpty; nodes = nodes[0].children) {
    answer.add(nodes[0].san);
  }
  String? tag(String key) {
    final value = tagValue(line.tags, key)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  int count(String key) => int.tryParse(tag(key) ?? '') ?? 0;
  return Puzzle(
    index: index,
    fen: tree.rootFen,
    answer: answer,
    kind: MistakeKind.of(tag('MistakeType')),
    played: tag('UserMove'),
    refutation: tag('OpponentBestResponse'),
    white: tag('White') ?? '',
    black: tag('Black') ?? '',
    date: tag('Date') ?? '',
    gameId: tag('GameId') ?? '',
    note: PuzzleNote.parse(tree.rootComment ?? tree.children[0].comment),
    stats: PuzzleStats(
      reviews: count('ReviewCount'),
      successes: count('SuccessCount'),
      lastReviewed: DateTime.tryParse(tag('LastReviewed') ?? ''),
      seconds: double.tryParse(tag('TimeToSolve') ?? ''),
      stars: count('StarRating').clamp(0, 5),
    ),
  );
}

/// Every puzzle of a set file's games, in file order.
List<Puzzle> puzzlesOf(List<ChapterLine> lines) => [
  for (final (index, line) in lines.indexed) ?puzzleOf(line, index),
];
