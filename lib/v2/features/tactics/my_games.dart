import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/fen.dart';
import '../../chess/pgn/pgn_reader.dart';
import '../../chess/tactics/game_ids.dart';
import '../../chess/tactics/mining.dart';
import '../../engines/engine.dart';
import '../../engines/engine_line.dart';
import '../../engines/engine_supervisor.dart';
import '../../net/recent_games.dart';
import '../../storage/pending_writes.dart';
import '../../storage/my_accounts.dart';
import '../../storage/my_games_files.dart';
import 'set_additions.dart';
import 'download_saves.dart';

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

enum MyGamesProblem {
  noAccounts,
  accountsUnreadable,
  gamesUnreadable,
  engine,
  setUnreadable,
  notSaved,
}

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
  late final _downloads = DownloadSaves(_cache, _store, pendingWrites);
  bool _retryingDownloads = false;
  final _corpusProblems = <GameSite, ({String username, String detail})>{};
  Map<GameSite, String> get corpusProblems => {
    for (final entry in _corpusProblems.entries) entry.key: entry.value.detail,
  };
  Map<GameSite, String> get downloadProblems => _downloads.problems;
  bool get retryingDownloads => _retryingDownloads;

  Future<void> retryDownloads() async {
    if (_disposed || running || _retryingDownloads) return;
    _retryingDownloads = true;
    notifyListeners();
    try {
      await _downloads.retry();
      await _retryCorpusReads();
      await load();
      final finished = switch (_status) {
        MyGamesDone() ||
        MyGamesFailed(problem: MyGamesProblem.gamesUnreadable) => true,
        _ => false,
      };
      if (downloadProblems.isEmpty && corpusProblems.isEmpty && finished) {
        _status = const MyGamesIdle();
      }
    } finally {
      _retryingDownloads = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _retryCorpusReads() async {
    for (final entry in _corpusProblems.entries.toList()) {
      final read = await _cache.snapshotNewest(
        entry.key,
        entry.value.username,
        max: reviewWindow,
      );
      if (read is CachedGamesSnapshot) {
        _corpusProblems.remove(entry.key);
      } else if (read is CachedGamesUnavailable) {
        _corpusProblems[entry.key] = (
          username: entry.value.username,
          detail: read.detail,
        );
      }
    }
  }

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
  int _accountRevision = 0;
  int _accountSaves = 0;
  final _accountRequests = Object();
  PendingObligation<bool>? _accountWrite;
  String? _accountProblem;
  String? _accountReadProblem;

  String? get accountProblem =>
      _accountProblem ??
      _accountReadProblem ??
      (!savingAccounts && pendingWrites.unfinished(_store).isNotEmpty
          ? 'Account changes are waiting to be saved.'
          : null);
  bool get accountsUnavailable => _accountReadProblem != null;
  bool get savingAccounts => _accountSaves > 0;
  bool get accountsUnsettled =>
      savingAccounts ||
      accountsUnavailable ||
      pendingWrites.unfinished(_store).isNotEmpty;

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
    if (_disposed) return;
    final revision = _accountRevision;
    await pendingWrites.settleFor(_store);
    if (_disposed || revision != _accountRevision) return;
    if (pendingWrites.unfinished(_store).isNotEmpty) {
      _accountReadProblem =
          'Account changes have not been saved. Retry saving the usernames.';
      notifyListeners();
      return;
    }
    AccountsRead read;
    try {
      read = await _store.snapshot();
    } on Object catch (error) {
      read = AccountsUnavailable(
        'The saved accounts could not be read: $error',
      );
    }
    if (_disposed || revision != _accountRevision) return;
    switch (read) {
      case AccountsSnapshot(:final accounts, revision: final current)
          when current == _store.revision:
        _accounts = accounts;
        _accountReadProblem = null;
      case AccountsSnapshot():
        _accountReadProblem = 'Accounts changed during the read. Retry.';
      case AccountsUnavailable(:final detail):
        _accountReadProblem = detail;
    }
    notifyListeners();
  }

  /// Keeps both usernames; a blank one forgets that account. Nothing is
  /// downloaded, and games a paused review left queued are let go: they
  /// may be another account's. Answers whether both were kept.
  Future<bool> saveUsernames({String? lichess, String? chesscom}) {
    if (_disposed || running || downloadProblems.isNotEmpty) {
      return Future.value(false);
    }
    _accountRevision++;
    final work = _saveUsernames(lichess?.trim(), chesscom?.trim());
    pendingWrites.watch(_accountRequests, work);
    return work;
  }

  Future<bool> _saveUsernames(String? lichess, String? chesscom) async {
    final earlier = pendingWrites.unfinished(_store).isNotEmpty;
    _accountSaves++;
    _accountProblem = null;
    late final PendingObligation<bool> entry;
    entry = pendingWrites.accept(
      resource: _store,
      label: 'Accounts',
      blocked: () => false,
      work: () async {
        final kept = await _writeUsernames(lichess, chesscom);
        if (kept && identical(_accountWrite, entry) && !_disposed) {
          _showUsernames(lichess, chesscom);
        }
        return kept;
      },
      problem: (kept) => kept ? null : 'Usernames were not saved.',
    );
    _accountWrite = entry;
    if (!_disposed) notifyListeners();
    try {
      if (!await entry.run() && earlier) await pendingWrites.retry(_store);
      if (identical(_accountWrite, entry)) {
        _accountProblem = entry.committed
            ? null
            : 'Your account names could not be saved.';
      }
      return entry.committed;
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
    } on Object {
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
    _accountProblem = null;
    _accountReadProblem = null;
    _corpusProblems.removeWhere(
      (site, failure) => _accounts[site]?.username != failure.username,
    );
    if (!running) {
      _queue = const [];
      _status = const MyGamesIdle();
    }
    notifyListeners();
  }

  /// The exact requested pair remains in the accepted operation after the
  /// dialog or owner goes away; retrying does not ask for the names again.
  Future<void> retryUsernames() async {
    if (savingAccounts) return;
    _accountSaves++;
    if (!_disposed) notifyListeners();
    try {
      await pendingWrites.retry(_store);
      _accountProblem = pendingWrites.unfinished(_store).isEmpty
          ? null
          : 'Your account names could not be saved.';
      await load();
    } finally {
      _accountSaves--;
      if (!_disposed) notifyListeners();
    }
  }

  /// Downloads and reviews, or carries on with the games a pause or a
  /// failure left queued.
  Future<void> start() {
    if (_disposed) return Future.value();
    if (accountsUnsettled) {
      notifyListeners();
      return Future.value();
    }
    return pendingWrites.track(this, _start(), label: 'Game review');
  }

  Future<void> _start() async {
    if (running || _retryingDownloads) return;
    if (downloadProblems.isNotEmpty || corpusProblems.isNotEmpty) {
      return retryDownloads();
    }
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
    if (accountsUnavailable) {
      _become(
        MyGamesFailed(
          MyGamesProblem.accountsUnreadable,
          detail: _accountReadProblem!,
        ),
      );
      return null;
    }
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
    if (games.isEmpty && corpusProblems.isNotEmpty) {
      _become(const MyGamesFailed(MyGamesProblem.gamesUnreadable));
      return null;
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
    switch (fetched) {
      case GamesFetched(:final games):
        await _downloads.accept(site, username, games, _now());
        if (!_disposed) await load();
      case final GamesNotFetched failed:
        problems[site] = failed;
    }
    // Reviews consume the same persisted corpus as an offline second launch.
    // An unacknowledged HTTP result stays solely in its retry obligation.
    final snapshot = await _cache.snapshotNewest(
      site,
      username,
      max: reviewWindow,
    );
    if (snapshot is CachedGamesUnavailable) {
      _corpusProblems[site] = (username: username, detail: snapshot.detail);
      return [];
    }
    _corpusProblems.remove(site);
    final texts = [
      for (final game in (snapshot as CachedGamesSnapshot).games) game.text,
    ];
    return [
      for (final text in texts)
        (site: site, username: username, id: gameIdIn(text), text: text),
    ];
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
    final start = await _engine();
    if (_disposed) {
      if (start case Started(:final engine)) await engine.quit();
      return;
    }
    switch (start) {
      case StartFailed(:final reason):
        _become(
          MyGamesFailed(MyGamesProblem.engine, detail: reason, added: added),
        );
      case Started(:final engine):
        _quit = engine.quit;
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
            await engine.quit();
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

  @override
  void dispose() {
    _disposed = true;
    unawaited(_quit?.call());
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
