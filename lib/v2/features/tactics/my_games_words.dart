import '../../chess/tactics/game_ids.dart';
import '../../net/recent_games.dart';
import 'my_games.dart';

/// The review of the user's games in the words the Tactics panel shows: one
/// line for where it stands.

String myGamesLine(MyGamesStatus status) => switch (status) {
  MyGamesIdle() => '',
  MyGamesDownloading(pausing: true) ||
  MyGamesReviewing(pausing: true) => 'Pausing…',
  MyGamesDownloading() => 'Getting your recent games…',
  MyGamesReviewing(:final done, :final total, :final notReached) =>
    'Looking for your mistakes… ${done < total ? done + 1 : total} of $total'
        '${_saved(notReached)}',
  MyGamesPaused(:final left) => 'Paused — ${_count(left, 'game')} left',
  MyGamesDone(:final added, :final notReached) =>
    'Review complete · ${_count(added, 'new puzzle')}${_saved(notReached)}',
  MyGamesNotDownloaded(:final problems) => [
    for (final MapEntry(key: site, value: failed) in problems.entries)
      _notFetched(site, failed),
  ].join(' '),
  MyGamesFailed(problem: MyGamesProblem.noAccounts) => 'Set a username first.',
  MyGamesFailed(problem: MyGamesProblem.setUnreadable) =>
    'Analysis failed: the tactics set could not be read.',
  MyGamesFailed(:final detail) => 'Analysis failed: $detail.',
};

String _count(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

/// Names the sites whose saved games stood in for a download.
String _saved(Set<GameSite> sites) => sites.isEmpty
    ? ''
    : ' · ${sites.map((s) => s.label).join(' and ')} not reached, '
          'using saved games';

String _notFetched(GameSite site, GamesNotFetched failed) =>
    switch (failed.problem) {
      GamesProblem.unreachable =>
        'Could not reach ${site.label}, and no games are saved.',
      GamesProblem.rateLimited =>
        '${site.label} is limiting requests; try again in a few minutes.',
      GamesProblem.noSuchPlayer =>
        '${site.label} has no player by that username.',
      GamesProblem.http =>
        '${site.label} could not answer (HTTP ${failed.status}).',
    };
