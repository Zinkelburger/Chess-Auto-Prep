import 'dart:math' as math;

import 'result.dart';

/// Completed results only. Seat indices, rather than engine names, identify
/// competitors: one binary can play on both sides of a match.
List<TournamentStanding> tournamentStandings(Tournament tournament) {
  final count = tournament.config.engines.length;
  final grid = List.generate(
    count,
    (_) => List.generate(count, (_) => <int>[0, 0, 0]),
  );
  for (final game in tournament.games) {
    if (game.white == game.black ||
        game.white < 0 ||
        game.black < 0 ||
        game.white >= count ||
        game.black >= count)
      continue;
    final outcome = switch (game.result) {
      '1-0' => 0,
      '1/2-1/2' => 1,
      '0-1' => 2,
      _ => null,
    };
    if (outcome == null) continue;
    grid[game.white][game.black][outcome]++;
    grid[game.black][game.white][2 - outcome]++;
  }
  final pairs = [
    for (final row in grid) [for (final c in row) MatchScore(c[0], c[1], c[2])],
  ];
  final totals = [
    for (final row in pairs)
      row.fold(const MatchScore(0, 0, 0), (a, b) => a.plus(b)),
  ];
  final rows = <TournamentStanding>[];
  for (var seat = 0; seat < count; seat++) {
    var sb = 0.0;
    for (var opponent = 0; opponent < count; opponent++) {
      sb += pairs[seat][opponent].points * totals[opponent].points;
    }
    rows.add(
      TournamentStanding(
        seat,
        tournament.config.engines[seat].name,
        totals[seat],
        List.unmodifiable(pairs[seat]),
        sb,
      ),
    );
  }
  rows.sort((a, b) {
    for (final comparison in [
      b.score.points.compareTo(a.score.points),
      b.sonnebornBerger.compareTo(a.sonnebornBerger),
      b.score.wins.compareTo(a.score.wins),
    ]) {
      if (comparison != 0) return comparison;
    }
    return a.seat.compareTo(b.seat);
  });
  return List.unmodifiable(rows);
}

final class TournamentStanding {
  const TournamentStanding(
    this.seat,
    this.name,
    this.score,
    this.opponents,
    this.sonnebornBerger,
  );
  final int seat;
  final String name;
  final MatchScore score;
  final List<MatchScore> opponents;
  final double sonnebornBerger;
}

final class MatchScore {
  const MatchScore(this.wins, this.draws, this.losses);
  final int wins, draws, losses;
  int get played => wins + draws + losses;
  double get points => wins + draws / 2;
  String get label =>
      '${points.toStringAsFixed(points == points.roundToDouble() ? 0 : 1)}/$played';
  MatchScore plus(MatchScore other) =>
      MatchScore(wins + other.wins, draws + other.draws, losses + other.losses);

  /// The legacy score-to-Elo convention. The finite estimate is undefined
  /// for an empty record or a perfect/zero score.
  double? get elo => played == 0 ? null : _rating(points / played);

  /// The legacy normal approximation in score space, transformed to Elo.
  /// Kept for comparison with existing reports; all-draw samples have zero
  /// plug-in variance, which is not evidence of certainty about future games.
  double? get margin {
    if (elo == null) return null;
    final mean = points / played;
    final variance =
        wins * math.pow(1 - mean, 2) +
        draws * math.pow(.5 - mean, 2) +
        losses * mean * mean;
    final band = 1.959963985 * math.sqrt(variance) / played;
    final low = _rating((mean - band).clamp(1e-9, 1 - 1e-9))!;
    final high = _rating((mean + band).clamp(1e-9, 1 - 1e-9))!;
    return (high - low) / 2;
  }

  /// Normal approximation of a positive decisive-game score. Evaluate the
  /// normal CDF numerically; draws and an empty record yield 50%.
  double get superiority {
    if (wins == losses) return .5;
    final z = (wins - losses) / math.sqrt(wins + losses);
    if (z.abs() >= 9) return z > 0 ? 1 : 0;
    // Simpson quadrature over [0, |z|], sufficiently precise for 0.1% UI.
    const steps = 120;
    final step = z.abs() / steps;
    var sum = 1 + math.exp(-z * z / 2);
    for (var i = 1; i < steps; i++) {
      final x = step * i;
      sum += (i.isEven ? 2 : 4) * math.exp(-x * x / 2);
    }
    final area = sum * step / (3 * math.sqrt(2 * math.pi));
    return .5 + (z < 0 ? -area : area);
  }
}

double? _rating(double score) => score <= 0 || score >= 1
    ? null
    : 400 * math.log(score / (1 - score)) / math.ln10;
