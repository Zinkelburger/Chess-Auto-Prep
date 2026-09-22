/// Orderings of a game list for each [GameSortMode].
///
/// Pure comparators shared by collection ordering and its tests.
library;

import '../../models/pgn_filter_models.dart';
import '../../models/pgn_game_entry.dart';
import '../../utils/pgn_date_utils.dart';

/// Where an unrated game (study rating 0) sits among rated ones: as a
/// middling rating, so it lands between good and bad rather than at an end.
const int _unratedSortsAs = 3;

/// Newest first. Undated games sort last rather than clumping at the top:
/// an empty key would otherwise beat every real date under a plain compare.
int compareGamesByDateDesc(PgnGameEntry a, PgnGameEntry b) {
  final ka = pgnHeaderSortKey(a.headers);
  final kb = pgnHeaderSortKey(b.headers);
  if (ka.isEmpty || kb.isEmpty) {
    if (ka.isEmpty && kb.isEmpty) return 0;
    return ka.isEmpty ? 1 : -1;
  }
  return kb.compareTo(ka);
}

int _ratingRank(PgnGameEntry game) =>
    game.studyRating == 0 ? _unratedSortsAs : game.studyRating;

/// Best-rated first.
int compareGamesByRatingDesc(PgnGameEntry a, PgnGameEntry b) =>
    _ratingRank(b).compareTo(_ratingRank(a));

/// Worst-rated first.
int compareGamesByRatingAsc(PgnGameEntry a, PgnGameEntry b) =>
    _ratingRank(a).compareTo(_ratingRank(b));

/// Sort [games] in place for [mode]. [GameSortMode.fileOrder] is not an
/// ordering of the list itself — the caller restores it from the full
/// collection — so it leaves [games] untouched.
void sortGamesInPlace(List<PgnGameEntry> games, GameSortMode mode) {
  switch (mode) {
    case GameSortMode.fileOrder:
      return;
    case GameSortMode.dateDesc:
      games.sort(compareGamesByDateDesc);
    case GameSortMode.ratingDesc:
      games.sort(compareGamesByRatingDesc);
    case GameSortMode.ratingAsc:
      games.sort(compareGamesByRatingAsc);
  }
}
