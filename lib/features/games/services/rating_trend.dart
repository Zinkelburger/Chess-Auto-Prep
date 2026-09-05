/// Rating-trend computation for the welcome header.
///
/// Groups the recent games by (platform, speed) and reports, per group, the
/// newest rating and its movement across the visible window. Elo headers are
/// the rating *at game start*, so the delta is "newest game's rating minus
/// oldest game's rating" — the last game's own result is not folded in, which
/// is fine for a two-week trend line. Pure and unit-tested.
library;

import '../../../services/games_library/game_filter.dart';
import '../../../services/games_library/games_library_service.dart';
import '../models/recent_game.dart';

class RatingTrendEntry {
  const RatingTrendEntry({
    required this.platform,
    required this.speed,
    required this.latestElo,
    required this.oldestElo,
    required this.gameCount,
  });

  final GamesPlatform platform;
  final GameSpeed speed;

  /// Rating at the newest game in the window.
  final int latestElo;

  /// Rating at the oldest game in the window.
  final int oldestElo;

  /// Rated games of mine in this group.
  final int gameCount;

  int get delta => latestElo - oldestElo;

  /// Whether the delta means anything (one game has no trend).
  bool get hasTrend => gameCount >= 2;

  /// Unknown-speed games are just "Games": a trend line needs a noun.
  String get speedLabel => speed == GameSpeed.unknown ? 'Games' : speed.label;

  String get platformLabel =>
      platform == GamesPlatform.chesscom ? 'Chess.com' : 'Lichess';
}

/// Compute trends from [games] (newest-first, as `RecentGamesController`
/// delivers them). Groups are returned most-played first, so `entries.first`
/// is the headline: the pool the user actually lives in.
List<RatingTrendEntry> computeRatingTrends(List<RecentGame> games) {
  final elosNewestFirst = <(GamesPlatform, GameSpeed), List<int>>{};
  for (final g in games) {
    final elo = g.myElo;
    if (elo == null) continue;
    elosNewestFirst
        .putIfAbsent((g.platform, g.record.speed), () => <int>[])
        .add(elo);
  }
  final entries = <RatingTrendEntry>[
    for (final e in elosNewestFirst.entries)
      RatingTrendEntry(
        platform: e.key.$1,
        speed: e.key.$2,
        latestElo: e.value.first,
        oldestElo: e.value.last,
        gameCount: e.value.length,
      ),
  ];
  entries.sort((a, b) => b.gameCount.compareTo(a.gameCount));
  return entries;
}
