/// Turns a list of played games into standings and a head-to-head grid.
///
/// Pure arithmetic over [TournamentGameRecord]s — no engines, no files — so
/// it is the piece the unit tests can pin down exactly.
library;

import 'dart:math' as math;

import '../models/crosstable.dart';
import '../models/tournament_config.dart';
import '../models/tournament_game.dart';

/// 95% two-sided normal quantile, the interval every engine tester quotes.
const double _z95 = 1.959963985;

Crosstable buildCrosstable(
  TournamentConfig config,
  List<TournamentGameRecord> games,
) {
  final count = config.engines.length;
  if (count == 0) {
    return const Crosstable(standings: [], grid: {}, totalGames: 0);
  }

  final points = List<double>.filled(count, 0);
  final played = List<int>.filled(count, 0);
  final wins = List<int>.filled(count, 0);
  final draws = List<int>.filled(count, 0);
  final losses = List<int>.filled(count, 0);

  // rowEngine -> columnEngine -> results in play order, row's perspective.
  final cellResults = <int, Map<int, List<String>>>{};
  final cellPoints = <int, Map<int, double>>{};

  void note(int self, int opponent, double score, String letter) {
    points[self] += score;
    played[self] += 1;
    if (score == 1) {
      wins[self] += 1;
    } else if (score == 0) {
      losses[self] += 1;
    } else {
      draws[self] += 1;
    }
    (cellResults[self] ??= {}).putIfAbsent(opponent, () => []).add(letter);
    final row = cellPoints[self] ??= {};
    row[opponent] = (row[opponent] ?? 0) + score;
  }

  for (final game in games) {
    final w = game.whiteIndex;
    final b = game.blackIndex;
    if (w < 0 || w >= count || b < 0 || b >= count) continue;
    final whiteScore = game.result.whitePoints;
    note(w, b, whiteScore, Crosstable.letterFor(game.result, asWhite: true));
    note(
      b,
      w,
      1 - whiteScore,
      Crosstable.letterFor(game.result, asWhite: false),
    );
  }

  // Sonneborn-Berger needs everyone's final totals, so it runs in a second
  // pass over the same games.
  final sb = List<double>.filled(count, 0);
  for (final game in games) {
    final w = game.whiteIndex;
    final b = game.blackIndex;
    if (w < 0 || w >= count || b < 0 || b >= count) continue;
    final whiteScore = game.result.whitePoints;
    sb[w] += whiteScore * points[b];
    sb[b] += (1 - whiteScore) * points[w];
  }

  final rows = <StandingsRow>[];
  for (var i = 0; i < count; i++) {
    final n = played[i];
    final fraction = n == 0 ? 0.0 : points[i] / n;
    final elo = _eloFromScore(fraction);
    rows.add(
      StandingsRow(
        rank: 0,
        engineIndex: i,
        name: config.engines[i].name,
        points: points[i],
        played: n,
        wins: wins[i],
        draws: draws[i],
        losses: losses[i],
        sonnebornBerger: sb[i],
        eloDiff: elo,
        eloMargin: _eloMargin(wins[i], draws[i], losses[i]),
        likelihoodOfSuperiority: likelihoodOfSuperiority(wins[i], losses[i]),
      ),
    );
  }

  rows.sort((a, b) {
    final byPoints = b.points.compareTo(a.points);
    if (byPoints != 0) return byPoints;
    final bySb = b.sonnebornBerger.compareTo(a.sonnebornBerger);
    if (bySb != 0) return bySb;
    final byWins = b.wins.compareTo(a.wins);
    if (byWins != 0) return byWins;
    return a.engineIndex.compareTo(b.engineIndex);
  });

  final ranked = [
    for (var i = 0; i < rows.length; i++)
      StandingsRow(
        rank: i + 1,
        engineIndex: rows[i].engineIndex,
        name: rows[i].name,
        points: rows[i].points,
        played: rows[i].played,
        wins: rows[i].wins,
        draws: rows[i].draws,
        losses: rows[i].losses,
        sonnebornBerger: rows[i].sonnebornBerger,
        eloDiff: rows[i].eloDiff,
        eloMargin: rows[i].eloMargin,
        likelihoodOfSuperiority: rows[i].likelihoodOfSuperiority,
      ),
  ];

  final grid = <int, Map<int, CrosstableCell>>{};
  for (var i = 0; i < count; i++) {
    final row = <int, CrosstableCell>{};
    for (var j = 0; j < count; j++) {
      if (i == j) continue;
      final results = cellResults[i]?[j];
      if (results == null || results.isEmpty) continue;
      row[j] = CrosstableCell(
        results: List.unmodifiable(results),
        points: cellPoints[i]?[j] ?? 0,
      );
    }
    grid[i] = row;
  }

  return Crosstable(standings: ranked, grid: grid, totalGames: games.length);
}

/// Rating difference implied by a score fraction. Null at 0% and 100%, where
/// the logit is infinite and no finite rating gap is implied.
double? _eloFromScore(double fraction) {
  if (fraction <= 0 || fraction >= 1) return null;
  final elo = -400 * (math.log(1 / fraction - 1) / math.ln10);
  // An even score yields negative zero, which renders as a signed "+-0".
  return elo == 0 ? 0.0 : elo;
}

/// Half-width of the 95% interval on the Elo estimate, from the spread of the
/// win/draw/loss outcomes — the standard engine-testing error bar.
double? _eloMargin(int wins, int draws, int losses) {
  final n = wins + draws + losses;
  if (n == 0) return null;
  final fraction = (wins + draws / 2) / n;
  if (fraction <= 0 || fraction >= 1) return null;
  final variance =
      wins * math.pow(1 - fraction, 2) +
      losses * math.pow(0 - fraction, 2) +
      draws * math.pow(0.5 - fraction, 2);
  final stdev = math.sqrt(variance / n) / math.sqrt(n);
  final low = _eloFromScore((fraction - _z95 * stdev).clamp(1e-9, 1 - 1e-9));
  final high = _eloFromScore((fraction + _z95 * stdev).clamp(1e-9, 1 - 1e-9));
  if (low == null || high == null) return null;
  return (high - low) / 2;
}

/// Probability the win/loss split reflects a real edge rather than noise.
/// Draws carry no information, which is why they are absent from the formula.
double likelihoodOfSuperiority(int wins, int losses) {
  final decisive = wins + losses;
  if (decisive == 0) return 0.5;
  return 0.5 * (1 + _erf((wins - losses) / math.sqrt(2.0 * decisive)));
}

/// Abramowitz & Stegun 7.1.26 — max error 1.5e-7, far below the precision
/// any number derived from a few hundred games deserves.
double _erf(double x) {
  final sign = x < 0 ? -1.0 : 1.0;
  final v = x.abs();
  const a1 = 0.254829592;
  const a2 = -0.284496736;
  const a3 = 1.421413741;
  const a4 = -1.453152027;
  const a5 = 1.061405429;
  const p = 0.3275911;
  final t = 1.0 / (1.0 + p * v);
  final y =
      1.0 -
      ((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t * math.exp(-v * v);
  return sign * y;
}
