/// The tournament results summary: standings plus the head-to-head grid.
///
/// Shaped after the crosstable every engine-testing tool prints — Scid vs
/// PC's Crosstable window, cutechess-cli's final ranking — so the numbers
/// mean what someone used to those tools expects.
library;

import 'tournament_game.dart';

/// One cell of the grid: how a player did against one opponent, in the order
/// the games were played, so `=1=0` reads as draw, win, draw, loss.
class CrosstableCell {
  const CrosstableCell({required this.results, required this.points});

  /// From the row player's point of view.
  final List<String> results;
  final double points;

  int get played => results.length;

  bool get isSelf => results.isEmpty && points == 0;
}

class StandingsRow {
  const StandingsRow({
    required this.rank,
    required this.engineIndex,
    required this.name,
    required this.points,
    required this.played,
    required this.wins,
    required this.draws,
    required this.losses,
    required this.sonnebornBerger,
    required this.eloDiff,
    required this.eloMargin,
    required this.likelihoodOfSuperiority,
  });

  final int rank;

  /// Index into `TournamentConfig.engines` — the row's real identity.
  final int engineIndex;

  final String name;
  final double points;
  final int played;
  final int wins;
  final int draws;
  final int losses;

  /// Sonneborn-Berger tiebreak: full score of everyone you beat plus half the
  /// score of everyone you drew.
  final double sonnebornBerger;

  /// Rating difference implied by the score, `-400·log10(1/s − 1)`. Null
  /// when the score is 0% or 100%, where the formula diverges.
  final double? eloDiff;

  /// Half-width of the 95% confidence interval on [eloDiff].
  final double? eloMargin;

  /// Probability this engine is genuinely stronger than the field it played,
  /// from the win/loss split alone (draws carry no information here).
  final double likelihoodOfSuperiority;

  double get scoreFraction => played == 0 ? 0 : points / played;
  double get drawFraction => played == 0 ? 0 : draws / played;

  /// `5.5/10` — the way a match score is always written.
  String get scoreLabel {
    final p = points == points.roundToDouble()
        ? points.toStringAsFixed(0)
        : points.toStringAsFixed(1);
    return '$p/$played';
  }
}

class Crosstable {
  const Crosstable({
    required this.standings,
    required this.grid,
    required this.totalGames,
  });

  /// Best first.
  final List<StandingsRow> standings;

  /// `grid[rowEngineIndex][columnEngineIndex]`, null on the diagonal.
  final Map<int, Map<int, CrosstableCell>> grid;

  final int totalGames;

  bool get isEmpty => standings.isEmpty;

  CrosstableCell? cell(int row, int column) => grid[row]?[column];

  /// Result letter for one game from [perspective]'s side.
  static String letterFor(GameResult result, {required bool asWhite}) {
    switch (result) {
      case GameResult.draw:
      case GameResult.unfinished:
        return '=';
      case GameResult.whiteWins:
        return asWhite ? '1' : '0';
      case GameResult.blackWins:
        return asWhite ? '0' : '1';
    }
  }
}
