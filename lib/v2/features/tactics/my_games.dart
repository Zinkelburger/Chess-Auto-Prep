import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/fen.dart';
import '../../chess/pgn/pgn_reader.dart';
import '../../chess/tactics/game_ids.dart';
import '../../chess/tactics/mining.dart';
import '../../engines/engine.dart';
import '../../diagnostics/log.dart';
import '../../engines/engine_line.dart';
import '../../engines/engine_supervisor.dart';
import '../../net/recent_games.dart';
import '../../storage/pending_writes.dart';
import '../../storage/my_accounts.dart';
import '../../storage/my_games_files.dart';
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
    PendingWrites? pendingWrites,
    required List<RecentGames> sites,
    required GamesCache cache,
    required SetAdditions set,
    required ReviewEngine engine,
    DateTime Function() now = DateTime.now,
  }) : pendingWrites = pendingWrites ?? set.pendingWrites,
       _store = accounts,
       _sites = sites,
       _cache = cache,
       _set = set,
       _engine = engine,
       _now = now;

  final PendingWrites pendingWrites;

  final AccountStore _store;
  final List<RecentGames> _sites;
  final GamesCache _cache;
  final SetAdditions _set;
  final ReviewEngine _engine;

  /// When a download came down, for its note and the account's date.
  final DateTime Function() _now;

  Map<GameSite, Account> _accounts = const {};
  MyGamesStatus _status = const MyGamesIdle();
  List<_Queued> _queue = const [];

  /// Quits the engine of the review under way; null between reviews.
  Future<void> Function()? _quit;
  bool _disposed = false;
  int _accountSaves = 0;
  String? _accountProblem;

  /// Why the last username change was not saved, or null. The names are
  /// shown and used anyway; changing them again tries again.
  String? get accountProblem => _accountProblem;
  bool get savingAccounts => _accountSaves > 0;
  bool get accountsUnsettled => savingAccounts;

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

  /// Reads the saved usernames. Preferences that cannot be read keep the
  /// names already shown, and the log says why.
  Future<void> load() async {
    if (_disposed) return;
    AccountsRead read;
    try {
      read = await _store.snapshot();
    } on Object catch (error) {
      read = AccountsUnavailable('$error');
    }
    if (_disposed) return;
    switch (read) {
      case AccountsSnapshot(:final accounts):
        _accounts = accounts;
      case AccountsUnavailable(:final detail):
        log.w('read the My games accounts', detail);
    }
    notifyListeners();
  }

  /// Keeps both usernames; a blank one forgets that account. Nothing is
  /// downloaded, and games a paused review left queued are let go: they
  /// may be another account's. Answers whether both were kept.
  Future<bool> saveUsernames({String? lichess, String? chesscom}) {
    if (_disposed || running) return Future.value(false);
    return pendingWrites.track(
      _store,
      _saveUsernames(lichess?.trim(), chesscom?.trim()),
      label: 'Accounts',
      problem: (kept) => kept ? null : 'Usernames were not saved.',
      obligation: _store,
    );
  }

  Future<bool> _saveUsernames(String? lichess, String? chesscom) async {
    _accountSaves++;
    if (!_disposed) notifyListeners();
    try {
      final kept = await _writeUsernames(lichess, chesscom);
      if (_disposed) return kept;
      _showUsernames(lichess, chesscom);
      _accountProblem = kept ? null : 'Your account names could not be saved.';
      return kept;
    } finally {
      _accountSaves--;
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> _writeUsernames(String? lichess, String? chesscom) async {
    try {
      final first = await _store.setUsername(GameSite.lichess, lichess);
      final second = await _store.setUsername(GameSite.chesscom, chesscom);
      return first && second;
    } on Object catch (error) {
      log.w('save the My games usernames', error);
      return false;
    }
  }

  void _showUsernames(String? lichess, String? chesscom) {
    _accounts = {
      for (final (site, name) in [
        (GameSite.lichess, lichess),
        (GameSite.chesscom, chesscom),
      ])
        if (name != null && name.isNotEmpty)
          site: Account(
            name,
            downloaded: _accounts[site]?.username == name
                ? _accounts[site]?.downloaded
                : null,
          ),
    };
    if (!running) {
      _queue = const [];
      _status = const MyGamesIdle();
    }
  }

  /// Downloads and reviews, or carries on with the games a pause or a
  /// failure left queued.
  Future<void> start() {
    if (_disposed || savingAccounts) return Future.value();
    return pendingWrites.track(this, _start(), label: 'Game review');
  }

  Future<void> _start() async {
    if (running) return;
    var (added, notReached) = switch (_status) {
      MyGamesPaused(:final added, :final notReached) => (added, notReached),
      MyGamesFailed(:final added) => (added, const <GameSite>{}),
      _ => (0, const <GameSite>{}),
    };
    if (_queue.isNotEmpty) {
      _become(MyGamesReviewing(done: 0, total: _queue.length, added: added));
      final retried = await _retryCheckpoints(added);
      if (retried == null || _disposed) return;
      added = retried;
      if (!await _dropDone()) return;
      if (_queue.isEmpty) {
        return _become(MyGamesDone(reviewed: 0, added: added));
      }
      return _review(notReached, added);
    }
    final missed = await _download();
    if (missed != null) await _review(missed, 0);
  }

  Future<int?> _retryCheckpoints(int added) async {
    while (_queue.isNotEmpty && _set.retained(_queue.first.id)) {
      final id = _queue.first.id;
      switch (await _set.retry(id)) {
        case Added(added: final more):
          added += more;
          _set.acknowledge(id);
          _queue = _queue.sublist(1);
        case NotAdded(:final reason):
          _become(
            MyGamesFailed(
              MyGamesProblem.notSaved,
              detail: reason,
              added: added,
            ),
          );
          return null;
        case null:
          return added;
      }
    }
    return added;
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
    await load();
    if (_accounts.isEmpty) {
      _become(const MyGamesFailed(MyGamesProblem.noAccounts));
      return null;
    }
    _become(const MyGamesDownloading());
    final games = <_Queued>[];
    final problems = <GameSite, GamesNotFetched>{};
    final accounts = Map<GameSite, Account>.of(_accounts);
    for (final source in _sites) {
      final account = accounts[source.site];
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
    final max = await _toAskFor(site, username);
    GamesFetch fetched;
    try {
      fetched = await source.recent(username, max: max);
    } on Object {
      fetched = const GamesNotFetched(GamesProblem.unreachable);
    }
    List<String>? fetchedGames;
    switch (fetched) {
      case GamesFetched(:final games):
        fetchedGames = games;
        await _keep(site, username, games, _now());
      case final GamesNotFetched failed:
        problems[site] = failed;
    }
    // The saved file is the review's source, as on an offline launch; games
    // that came down but could not be saved are reviewed all the same.
    final snapshot = await _cache.snapshotNewest(
      site,
      username,
      max: reviewWindow,
    );
    final List<String> texts;
    if (snapshot is CachedGamesSnapshot &&
        (snapshot.games.isNotEmpty || fetchedGames == null)) {
      texts = [for (final game in snapshot.games) game.text];
    } else {
      if (snapshot case CachedGamesUnavailable(:final detail)) {
        log.w('read the saved ${site.label} games', detail);
      }
      texts = fetchedGames?.take(reviewWindow).toList() ?? const [];
    }
    return [
      for (final text in texts)
        (site: site, username: username, id: gameIdIn(text), text: text),
    ];
  }

  /// Saves a download and dates the account by it. The file is a cache: a
  /// save that fails is logged, and the next download simply tries again.
  Future<void> _keep(
    GameSite site,
    String username,
    List<String> games,
    DateTime when,
  ) async {
    try {
      final kept = await _cache.keep(site, username, games, when);
      if (kept case GamesNotKept(:final detail)) {
        log.w('save the ${site.label} download', detail);
        return;
      }
      if (await _store.setDownloaded(site, when, expectedUsername: username) &&
          _accounts[site]?.username == username) {
        _accounts = {..._accounts, site: Account(username, downloaded: when)};
      }
    } on Object catch (error) {
      log.w('save the ${site.label} download', error);
    }
  }

  /// The review looks at the newest [reviewWindow] games, and the book check
  /// reads the newest [bookCheckWindow] saved ones: until that many are
  /// saved, a download asks for that many, and after that only for what a
  /// review needs.
  Future<int> _toAskFor(GameSite site, String username) async {
    final saved = await _cache.snapshotNewest(
      site,
      username,
      max: bookCheckWindow,
    );
    final count = saved is CachedGamesSnapshot ? saved.games.length : 0;
    return count < bookCheckWindow ? bookCheckWindow : reviewWindow;
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
    final EngineStart start;
    try {
      start = await _engine();
    } on Object catch (error) {
      _become(
        MyGamesFailed(MyGamesProblem.engine, detail: '$error', added: added),
      );
      return;
    }
    if (_disposed) {
      if (start case Started(:final engine)) await _release(engine.quit);
      return;
    }
    switch (start) {
      case StartFailed(:final reason):
        _become(
          MyGamesFailed(MyGamesProblem.engine, detail: reason, added: added),
        );
      case Started(:final engine):
        Future<void>? stopping;
        Future<void> stop() => stopping ??= Future<void>.sync(engine.quit);
        _quit = stop;
        MyGamesStatus ended;
        try {
          ended = await _reviewQueue(engine, total, added, notReached);
        } on Object catch (error) {
          ended = MyGamesFailed(
            MyGamesProblem.engine,
            detail: '$error',
            added: newPuzzles,
          );
        } finally {
          try {
            await stop();
          } on Object catch (error) {
            ended = MyGamesFailed(
              MyGamesProblem.engine,
              detail: 'Could not confirm Stockfish stopped: $error',
              added: newPuzzles,
            );
          } finally {
            _quit = null;
          }
        }
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
          _set.acknowledge(game.id);
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

  /// A disposed view cannot display a stop failure, but must still consume it.
  /// The supervisor retains native process ownership through confirmed exit.
  Future<void> _release(Future<void> Function() stop) async {
    try {
      await stop();
    } on Object catch (error) {
      log.w('stop the tactics review engine', error.runtimeType);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_quit case final stop?) unawaited(_release(stop));
    super.dispose();
  }
}

/// The depth every move is judged at: the old app's default, so the same
/// game gives the same puzzles in both apps.
const reviewDepth = 15;

/// The engine's pass over one of the user's games: the position before each
/// of their moves, and the one after it unless they played the engine's own
/// choice. Answers the puzzles the game's mistakes make, an empty list for a
/// game that is not theirs, not standard chess or not readable, and null
/// when the engine stopped answering part way — the game is then not done,
/// and is looked at again next time.
Future<List<MinedPuzzle>?> reviewGame(
  Engine engine,
  String gameText,
  String username,
) async {
  final read = readGame(gameText);
  final tree = read.tree;
  final side = sideOf(read.tags, username);
  if (tree == null || side == null || !isStandardChess(read.tags)) {
    return const [];
  }
  final game = SourceGame.of(read.tags, tree, gameIdIn(gameText));
  final found = <MinedPuzzle>[];
  for (final move in movesBy(tree, side)) {
    if (isOver(move.after)) continue;
    final before = await verdictAt(engine, move.before, depth: reviewDepth);
    if (before == null) return null;
    if (playedBest(move, before)) continue;
    final after = await verdictAt(engine, move.after, depth: reviewDepth);
    if (after == null) return null;
    final puzzle = minedFrom(move, before, after, game);
    if (puzzle != null) found.add(puzzle);
  }
  return found;
}

/// One fixed-depth search of [fen]: the last best line the engine reported,
/// or null when it reached neither [depth] nor a mate — an engine that died
/// or was quit under the review.
Future<Verdict?> verdictAt(Engine engine, Fen fen, {required int depth}) async {
  EngineLine? last;
  try {
    final search = engine.analyse(fen, multiPv: 1, depth: depth);
    await for (final line in search.lines) {
      if (line.multiPv == 1) last = line;
    }
  } on EngineFailure {
    return null;
  }
  if (last == null) return null;
  if (last.depth < depth && last.score is! MateIn && last.pv.isNotEmpty) {
    return null;
  }
  return switch (last.score) {
    Centipawns(:final value) => Verdict(cp: value, pv: last.pv),
    MateIn(:final moves) => Verdict(mate: moves, pv: last.pv),
  };
}
