import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/tactics/game_ids.dart';
import '../../engines/engine.dart';
import '../../engines/engine_supervisor.dart';
import '../../net/recent_games.dart';
import '../../storage/my_accounts.dart';
import '../../storage/my_games_files.dart';
import 'game_review.dart';
import 'set_additions.dart';

/// How many of each account's newest games a review looks at: the old
/// app's `last 20 games`.
const reviewWindow = 20;

/// Where the review of the user's games stands. `my_games_words.dart` has
/// the one line the screen shows for each.
sealed class MyGamesStatus {
  const MyGamesStatus();
}

final class MyGamesIdle extends MyGamesStatus {
  const MyGamesIdle();
}

final class MyGamesDownloading extends MyGamesStatus {
  const MyGamesDownloading({this.pausing = false});

  /// Pause was pressed: the review stops once the games are in.
  final bool pausing;
}

/// [done] of [total] games are reviewed, and [added] puzzles are in the
/// set. [notReached] are the sites whose download did not happen, so their
/// saved games stood in.
final class MyGamesReviewing extends MyGamesStatus {
  const MyGamesReviewing({
    required this.done,
    required this.total,
    this.added = 0,
    this.pausing = false,
    this.notReached = const {},
  });

  final int done;
  final int total;
  final int added;

  /// Pause was pressed: the review stops after the game being looked at.
  final bool pausing;
  final Set<GameSite> notReached;
}

final class MyGamesPaused extends MyGamesStatus {
  const MyGamesPaused({
    required this.left,
    this.added = 0,
    this.notReached = const {},
  });

  final int left;
  final int added;
  final Set<GameSite> notReached;
}

final class MyGamesDone extends MyGamesStatus {
  const MyGamesDone({
    required this.reviewed,
    this.added = 0,
    this.notReached = const {},
  });

  final int reviewed;
  final int added;
  final Set<GameSite> notReached;
}

/// No games came down and none are saved for the accounts that failed.
final class MyGamesNotDownloaded extends MyGamesStatus {
  const MyGamesNotDownloaded(this.problems);

  final Map<GameSite, GamesNotFetched> problems;
}

enum MyGamesProblem { noAccounts, engine, setUnreadable, notSaved }

/// The review stopped. Games not reviewed yet stay queued: start carries on.
final class MyGamesFailed extends MyGamesStatus {
  const MyGamesFailed(this.problem, {this.detail = '', this.added = 0});

  final MyGamesProblem problem;

  /// For the log and the end of the line.
  final String detail;
  final int added;
}

/// Starts the engine a review runs on; the review quits it when it is over.
typedef ReviewEngine = Future<EngineStart> Function();

/// A game waiting to be reviewed.
typedef _Queued = ({GameSite site, String username, String id, String text});

/// The user's accounts and the review of their games: download the newest
/// games of each account, let Stockfish judge every move the user made in
/// them, and add their mistakes to the tactics set as puzzles.
///
/// One pausable job. Pause stops after the game being reviewed; start again
/// carries on with the games still queued, without downloading them again.
/// A game is marked done in the same write that adds its puzzles, so one
/// cut off half way is reviewed again next time, and one either app has
/// done is never reviewed twice. A site that cannot be reached is answered
/// from the games saved on this computer.
final class MyGames extends ChangeNotifier {
  MyGames({
    required AccountStore accounts,
    required List<RecentGames> sites,
    required GamesCache cache,
    required SetAdditions set,
    required ReviewEngine engine,
  }) : _store = accounts,
       _sites = sites,
       _cache = cache,
       _set = set,
       _engine = engine;

  final AccountStore _store;
  final List<RecentGames> _sites;
  final GamesCache _cache;
  final SetAdditions _set;
  final ReviewEngine _engine;

  Map<GameSite, Account> _accounts = const {};
  MyGamesStatus _status = const MyGamesIdle();
  List<_Queued> _queue = const [];

  /// Quits the engine of the review under way; null between reviews.
  Future<void> Function()? _quit;
  bool _disposed = false;

  /// The accounts with a username, and when each last downloaded.
  Map<GameSite, Account> get accounts => _accounts;

  MyGamesStatus get status => _status;

  bool get running =>
      _status is MyGamesDownloading || _status is MyGamesReviewing;

  /// How many puzzles this review has added so far.
  int get newPuzzles => switch (_status) {
    MyGamesReviewing(:final added) ||
    MyGamesPaused(:final added) ||
    MyGamesDone(:final added) ||
    MyGamesFailed(:final added) => added,
    _ => 0,
  };

  /// How many games are waiting for a start to carry on with.
  int get queued => _queue.length;

  /// Reads the saved usernames.
  Future<void> load() async {
    final read = await _store.read();
    if (_disposed) return;
    _accounts = read;
    notifyListeners();
  }

  /// Keeps both usernames; a blank one forgets that account. Nothing is
  /// downloaded, and games a paused review left queued are let go: they
  /// may be another account's. Answers whether both were kept.
  Future<bool> saveUsernames({String? lichess, String? chesscom}) async {
    final kept =
        await _store.setUsername(GameSite.lichess, lichess) &
        await _store.setUsername(GameSite.chesscom, chesscom);
    if (!running) {
      _queue = const [];
      _status = const MyGamesIdle();
    }
    await load();
    return kept;
  }

  /// Downloads and reviews, or carries on with the games a pause or a
  /// failure left queued.
  Future<void> start() async {
    if (running) return;
    final (added, notReached) = switch (_status) {
      MyGamesPaused(:final added, :final notReached) => (added, notReached),
      MyGamesFailed(:final added) => (added, const <GameSite>{}),
      _ => (0, const <GameSite>{}),
    };
    if (_queue.isNotEmpty) {
      _become(MyGamesReviewing(done: 0, total: _queue.length, added: added));
      if (!await _dropDone()) return;
      if (_queue.isEmpty) {
        return _become(MyGamesDone(reviewed: 0, added: added));
      }
      return _review(notReached, added);
    }
    final missed = await _download();
    if (missed != null) await _review(missed, 0);
  }

  /// Stops after the game being reviewed, or once the games are in.
  void pause() {
    switch (_status) {
      case MyGamesDownloading():
        _become(const MyGamesDownloading(pausing: true));
      case final MyGamesReviewing r:
        _become(
          MyGamesReviewing(
            done: r.done,
            total: r.total,
            added: r.added,
            pausing: true,
            notReached: r.notReached,
          ),
        );
      default:
        break;
    }
  }

  bool get _pausing => switch (_status) {
    MyGamesDownloading(:final pausing) => pausing,
    MyGamesReviewing(:final pausing) => pausing,
    _ => false,
  };

  /// Fetches every account's games and queues the ones not reviewed yet.
  /// Answers the sites that were not reached when there is something to
  /// review now, or null when the job ends here.
  Future<Set<GameSite>?> _download() async {
    if (_accounts.isEmpty) await load();
    if (_accounts.isEmpty) {
      _become(const MyGamesFailed(MyGamesProblem.noAccounts));
      return null;
    }
    _become(const MyGamesDownloading());
    final games = <_Queued>[];
    final problems = <GameSite, GamesNotFetched>{};
    for (final source in _sites) {
      final account = _accounts[source.site];
      if (account == null) continue;
      games.addAll(await _gamesOf(source, account.username, problems));
      if (_disposed) return null;
    }
    if (games.isEmpty && problems.isNotEmpty) {
      _become(MyGamesNotDownloaded(problems));
      return null;
    }
    _queue = games;
    if (!await _dropDone()) return null;
    final missed = problems.keys.toSet();
    if (_queue.isEmpty) {
      _become(MyGamesDone(reviewed: 0, notReached: missed));
      return null;
    }
    if (_pausing) {
      _become(MyGamesPaused(left: _queue.length, notReached: missed));
      return null;
    }
    return missed;
  }

  /// [username]'s newest games from [source], kept for the next time the
  /// site cannot be reached; or the kept ones when it cannot be now.
  Future<List<_Queued>> _gamesOf(
    RecentGames source,
    String username,
    Map<GameSite, GamesNotFetched> problems,
  ) async {
    final site = source.site;
    final List<String> texts;
    switch (await source.recent(username, max: reviewWindow)) {
      case GamesFetched(:final games):
        final when = DateTime.now();
        await _cache.keep(site, username, games, when);
        await _store.setDownloaded(site, when);
        _accounts = {..._accounts, site: Account(username, downloaded: when)};
        texts = games;
      case final GamesNotFetched failed:
        problems[site] = failed;
        texts = await _cache.read(site, username, max: reviewWindow) ?? [];
    }
    return [
      for (final text in texts)
        (site: site, username: username, id: gameIdIn(text), text: text),
    ];
  }

  /// Takes the games either app has reviewed since they were queued off the
  /// queue, and any game with no id, which nothing could mark as done.
  /// False when the set could not be read, which ends the job.
  Future<bool> _dropDone() async {
    final done = await _set.analyzed();
    if (_disposed) return false;
    if (done == null) {
      _become(const MyGamesFailed(MyGamesProblem.setUnreadable));
      return false;
    }
    final seen = <String>{...done, ''};
    _queue = [
      for (final game in _queue)
        if (seen.add(game.id)) game,
    ];
    return true;
  }

  Future<void> _review(Set<GameSite> notReached, int added) async {
    final total = _queue.length;
    _become(
      MyGamesReviewing(
        done: 0,
        total: total,
        added: added,
        pausing: _pausing,
        notReached: notReached,
      ),
    );
    final start = await _engine();
    if (_disposed) {
      if (start case Started(:final engine)) await engine.quit();
      return;
    }
    switch (start) {
      case StartFailed(:final reason):
        _become(MyGamesFailed(MyGamesProblem.engine, detail: reason));
      case Started(:final engine):
        _quit = engine.quit;
        final ended = await _reviewQueue(engine, total, added, notReached);
        _quit = null;
        await engine.quit();
        if (!_disposed) _become(ended);
    }
  }

  /// Reviews the queued games one after another until they are all done, a
  /// pause is asked for or something fails; answers where that leaves it.
  Future<MyGamesStatus> _reviewQueue(
    Engine engine,
    int total,
    int added,
    Set<GameSite> notReached,
  ) async {
    var done = 0;
    while (_queue.isNotEmpty && !_pausing) {
      final game = _queue.first;
      final found = await reviewGame(engine, game.text, game.username);
      if (_disposed) return _status;
      if (found == null) {
        return MyGamesFailed(
          MyGamesProblem.engine,
          detail: 'Stockfish stopped answering',
          added: added,
        );
      }
      switch (await _set.add(game.id, found)) {
        case NotAdded(:final reason):
          return MyGamesFailed(
            MyGamesProblem.notSaved,
            detail: reason,
            added: added,
          );
        case Added(added: final more):
          added += more;
      }
      _queue = _queue.sublist(1);
      done++;
      _become(
        MyGamesReviewing(
          done: done,
          total: total,
          added: added,
          pausing: _pausing,
          notReached: notReached,
        ),
      );
    }
    return _queue.isEmpty
        ? MyGamesDone(reviewed: done, added: added, notReached: notReached)
        : MyGamesPaused(
            left: _queue.length,
            added: added,
            notReached: notReached,
          );
  }

  void _become(MyGamesStatus status) {
    if (_disposed) return;
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_quit?.call());
    super.dispose();
  }
}
