import 'dart:math';

/// An evaluation as the engine reports it: from the side to move, until
/// [forWhite] turns it round for display.
sealed class Score {
  const Score();

  Score get negated;

  /// The same score from White's side; UCI gives it from the side to move.
  Score forWhite({required bool whiteToMove}) => whiteToMove ? this : negated;

  /// `+0.35`, `-1.20`, `#3`, `#-3`.
  String get text;

  /// The share of the point the favoured side is expected to score, 0 to
  /// 1, using Lichess's fit of centipawns to results. A mate is 0 or 1.
  double get expected;
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
  double get expected => 1 / (1 + exp(-0.00368208 * value));

  @override
  bool operator ==(Object other) => other is Centipawns && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Centipawns($value)';
}

/// Mate in [moves]: positive when the side scores mates, negative when it
/// is mated, zero when it already is.
final class MateIn extends Score {
  const MateIn(this.moves);

  final int moves;

  @override
  Score get negated => MateIn(-moves);

  @override
  String get text => moves >= 0 ? '#$moves' : '#-${-moves}';

  @override
  double get expected => moves > 0 ? 1 : 0;

  @override
  bool operator ==(Object other) => other is MateIn && other.moves == moves;

  @override
  int get hashCode => moves.hashCode;

  @override
  String toString() => 'MateIn($moves)';
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

  /// The moves as UCI, from the analysed position.
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
  if (depth == null || score == null || pv == null || pv.isEmpty) return null;
  return EngineLine(multiPv: multiPv, depth: depth, score: score, pv: pv);
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
