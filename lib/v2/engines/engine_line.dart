/// An evaluation as the engine reports it: from the side to move, until
/// [forWhite] turns it round for display.
sealed class Score {
  const Score();

  Score get negated;

  /// The same score from White's side; UCI gives it from the side to move.
  Score forWhite({required bool whiteToMove}) => whiteToMove ? this : negated;

  /// `+0.35`, `-1.20`, `#3`, `#-3`.
  String get text;
}

final class Centipawns extends Score {
  const Centipawns(this.value);

  final int value;

  @override
  Score get negated => Centipawns(-value);

  @override
  String get text {
    final pawns = (value / 100).toStringAsFixed(2);
    return value < 0 ? pawns : '+$pawns';
  }

  @override
  bool operator ==(Object other) => other is Centipawns && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Centipawns($value)';
}

/// Mate in [moves]: positive when the side the score is about gives the
/// mate, negative when that side is the one being mated, and zero when the
/// board is checkmate already, which UCI reports as `score mate 0` for the
/// side to move in it — a loss.
///
/// A mate that has happened has no distance left to carry its sign, so
/// [mating] carries it instead. Without that, the mated side and the side
/// that just mated would be the same score, and a verdict on a finished
/// game could not say who won it.
final class MateIn extends Score {
  /// UCI's `score mate N` for the side to move.
  const MateIn(int moves) : this._(moves, mating: moves > 0);

  const MateIn._(this.moves, {required this.mating});

  /// How far off the mate is, zero once it is on the board.
  final int moves;

  /// Whether the side this score is about is the one giving the mate.
  final bool mating;

  @override
  Score get negated => MateIn._(-moves, mating: !mating);

  /// `#3`, `#-3`, and a bare `#` for a mate that has already happened: there
  /// is no distance to print.
  @override
  String get text => switch (moves) {
    0 => '#',
    _ => mating ? '#$moves' : '#-${moves.abs()}',
  };

  @override
  bool operator ==(Object other) =>
      other is MateIn && other.moves == moves && other.mating == mating;

  @override
  int get hashCode => Object.hash(moves, mating);

  @override
  String toString() => 'MateIn($text)';
}

/// One line of analysis: the engine's [multiPv]-th best continuation.
final class EngineLine {
  const EngineLine({
    required this.multiPv,
    required this.depth,
    required this.score,
    required this.pv,
  });

  /// 1 for the best line.
  final int multiPv;
  final int depth;
  final Score score;

  /// The moves as UCI, from the analysed position. Empty when the engine
  /// gave a score and no moves, which is what a finished game gets.
  final List<String> pv;

  EngineLine forWhite({required bool whiteToMove}) => EngineLine(
    multiPv: multiPv,
    depth: depth,
    score: score.forWhite(whiteToMove: whiteToMove),
    pv: pv,
  );
}

/// Reads a UCI `info` line. Null for the lines with nothing to show:
/// `info string`, `currmove` progress, and bound scores (`lowerbound`,
/// `upperbound`) the engine replaces within milliseconds.
///
/// A score with no moves after it is a line all the same. It is what an
/// engine says about a position that is already over — Stockfish answers
/// `info depth 0 score mate 0` and then `bestmove (none)` on a board that is
/// checkmate, and `score cp 0` on a stalemate — and dropping it would leave
/// a finished game with no score at all.
EngineLine? parseInfoLine(String line) {
  final words = line.trim().split(_spaces);
  if (words.first != 'info') return null;
  int? depth;
  var multiPv = 1;
  Score? score;
  List<String>? pv;
  for (var i = 1; i < words.length; i++) {
    switch (words[i]) {
      case 'depth':
        depth = int.tryParse(_word(words, i + 1));
      case 'multipv':
        multiPv = int.tryParse(_word(words, i + 1)) ?? 1;
      case 'score':
        score = _score(_word(words, i + 1), _word(words, i + 2));
      case 'lowerbound' || 'upperbound':
        return null;
      case 'pv':
        pv = words.sublist(i + 1);
        i = words.length;
    }
  }
  if (depth == null || score == null) return null;
  return EngineLine(
    multiPv: multiPv,
    depth: depth,
    score: score,
    pv: pv ?? const [],
  );
}

String _word(List<String> words, int i) => i < words.length ? words[i] : '';

Score? _score(String kind, String value) {
  final n = int.tryParse(value);
  if (n == null) return null;
  return switch (kind) {
    'cp' => Centipawns(n),
    'mate' => MateIn(n),
    _ => null,
  };
}

final _spaces = RegExp(r'\s+');
