/// Turns a list of played games into standings and a head-to-head grid.
///
/// Pure arithmetic over [CrosstableGame]s — no engines, no files, not even a
/// board — so it is the piece the unit tests can pin down exactly, and the
/// piece both the one-board and the two-board tournaments share.
library;

import 'dart:math' as math;

import '../models/crosstable.dart';

/// 95% two-sided normal quantile, the interval every engine tester quotes.
const double _z95 = 1.959963985;

/// Score fractions are clamped just inside (0, 1) before the Elo transform,
/// whose logit is infinite at either end.
const double _scoreEpsilon = 1e-9;

/// [names] are the participants in seeding order; a game's `whiteIndex` and
/// `blackIndex` index into it. Games naming a participant outside [names]
/// are ignored.
Crosstable buildCrosstable(List<String> names, List<CrosstableGame> games) {
  final count = names.length;
  if (count == 0) {
    return const Crosstable(standings: [], grid: {}, totalGames: 0);
  }

  final tally = _Tally(count);
  final valid = [
    for (final game in games)
      if (tally.covers(game.whiteIndex) && tally.covers(game.blackIndex)) game,
  ];
  for (final game in valid) {
    tally.record(game);
  }
  // Sonneborn-Berger needs everyone's final totals, so it runs in a second
  // pass over the same games.
  for (final game in valid) {
    tally.recordTiebreak(game);
  }

  return Crosstable(
    standings: tally.standings(names),
    grid: tally.grid(),
    totalGames: games.length,
  );
}

/// Per-participant totals and per-pairing results, accumulated game by game.
class _Tally {
  _Tally(this.count)
    : points = List.filled(count, 0),
      played = List.filled(count, 0),
      wins = List.filled(count, 0),
      draws = List.filled(count, 0),
      losses = List.filled(count, 0),
      sonnebornBerger = List.filled(count, 0);

  final int count;
  final List<double> points;
  final List<int> played;
  final List<int> wins;
  final List<int> draws;
  final List<int> losses;
  final List<double> sonnebornBerger;

  /// rowEngine -> columnEngine -> results in play order, row's perspective.
  final Map<int, Map<int, List<String>>> _cellResults = {};
  final Map<int, Map<int, double>> _cellPoints = {};

  bool covers(int index) => index >= 0 && index < count;

  void record(CrosstableGame game) {
    final whiteScore = game.result.whitePoints;
    _note(
      game.whiteIndex,
      game.blackIndex,
      whiteScore,
      Crosstable.letterFor(game.result, asWhite: true),
    );
    _note(
      game.blackIndex,
      game.whiteIndex,
      1 - whiteScore,
      Crosstable.letterFor(game.result, asWhite: false),
    );
  }

  /// Sonneborn-Berger: full score of everyone you beat plus half the score
  /// of everyone you drew. Call only after every game is [record]ed.
  void recordTiebreak(CrosstableGame game) {
    final whiteScore = game.result.whitePoints;
    sonnebornBerger[game.whiteIndex] += whiteScore * points[game.blackIndex];
    sonnebornBerger[game.blackIndex] +=
        (1 - whiteScore) * points[game.whiteIndex];
  }

  void _note(int self, int opponent, double score, String letter) {
    points[self] += score;
    played[self] += 1;
    if (score == 1) {
      wins[self] += 1;
    } else if (score == 0) {
      losses[self] += 1;
    } else {
      draws[self] += 1;
    }
    (_cellResults[self] ??= {}).putIfAbsent(opponent, () => []).add(letter);
    final row = _cellPoints[self] ??= {};
    row[opponent] = (row[opponent] ?? 0) + score;
  }

  /// Rows ranked best first: points, then Sonneborn-Berger, then wins, then
  /// seeding order.
  List<StandingsRow> standings(List<String> names) {
    final order = List.generate(count, (i) => i)
      ..sort((a, b) {
        final byPoints = points[b].compareTo(points[a]);
        if (byPoints != 0) return byPoints;
        final bySb = sonnebornBerger[b].compareTo(sonnebornBerger[a]);
        if (bySb != 0) return bySb;
        final byWins = wins[b].compareTo(wins[a]);
        if (byWins != 0) return byWins;
        return a.compareTo(b);
      });
    return [
      for (var rank = 1; rank <= order.length; rank++)
        _row(order[rank - 1], rank: rank, name: names[order[rank - 1]]),
    ];
  }

  StandingsRow _row(int i, {required int rank, required String name}) {
    final n = played[i];
    return StandingsRow(
      rank: rank,
      engineIndex: i,
      name: name,
      points: points[i],
      played: n,
      wins: wins[i],
      draws: draws[i],
      losses: losses[i],
      sonnebornBerger: sonnebornBerger[i],
      eloDiff: _eloFromScore(n == 0 ? 0.0 : points[i] / n),
      eloMargin: _eloMargin(wins[i], draws[i], losses[i]),
      likelihoodOfSuperiority: likelihoodOfSuperiority(wins[i], losses[i]),
    );
  }

  /// `grid[row][column]` for every pairing that played at least one game;
  /// every row is present, the diagonal never is.
  Map<int, Map<int, CrosstableCell>> grid() => {
    for (var i = 0; i < count; i++)
      i: {
        for (var j = 0; j < count; j++)
          if (i != j)
            if (_cellResults[i]?[j] case final results? when results.isNotEmpty)
              j: CrosstableCell(
                results: List.unmodifiable(results),
                points: _cellPoints[i]?[j] ?? 0,
              ),
      },
  };
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
/// win/draw/loss outcomes — the standard engine-testing error bar, and
/// byte-for-byte the cutechess-cli convention.
///
/// `variance / n` is the plug-in variance of one game's result about the mean,
/// so its root over another `sqrt(n)` is the **standard error of the mean**,
/// not a standard deviation. The band is taken symmetrically in score space
/// and mapped through [_eloFromScore] at each end.
///
/// Three edges are worth knowing before trusting the number, all inherited
/// from the plug-in estimator rather than introduced here:
///
///  * **An all-draw record reports ±0.** Every game equals the mean, so the
///    plug-in variance is exactly zero and ten straight draws render as
///    "0 ±0" — certainty from ten games. A Wilson or Agresti–Coull interval
///    would not do this. Deliberately not pinned by a test, so that fixing it
///    does not have to fight one.
///  * **The ± is not symmetric about the estimate.** The interval is symmetric
///    in score space and the Elo transform is convex, so at 70% over 100 games
///    the true band is [86.2, 218.3] around 147.2 — 61.0 below, 71.1 above —
///    reported as a single ±66.0. A crosstable that wants an honest bar needs
///    `low`/`high`, not a half-width.
///  * **The clamp turns "no information" into ±3600.** One win and one loss
///    pushes both ends outside (0, 1); they clamp, and the margin comes back
///    at that ceiling. Anything sitting at it means unbounded.
double? _eloMargin(int wins, int draws, int losses) {
  final n = wins + draws + losses;
  if (n == 0) return null;
  final fraction = (wins + draws / 2) / n;
  if (fraction <= 0 || fraction >= 1) return null;
  final variance =
      wins * math.pow(1 - fraction, 2) +
      losses * math.pow(0 - fraction, 2) +
      draws * math.pow(0.5 - fraction, 2);
  final standardError = math.sqrt(variance / n) / math.sqrt(n);
  final low = _eloFromScore(
    (fraction - _z95 * standardError).clamp(_scoreEpsilon, 1 - _scoreEpsilon),
  );
  final high = _eloFromScore(
    (fraction + _z95 * standardError).clamp(_scoreEpsilon, 1 - _scoreEpsilon),
  );
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
