/// The review of your recent games, as one pausable job.
///
/// Reviewing is three things: get the games, check them against your book, and
/// let the engine look at every move you made — which both counts your
/// mistakes and turns the worst of them into puzzles. Those last two used to be
/// separate passes over the same positions (a full-game analysis for the
/// counts, then mining for the puzzles). They are one pass now: the miner
/// reports each game's counts as it finishes (see [GameReviewStore]), so the
/// engine evaluates each position once.
///
/// With auto-start enabled, opening the app checks for new games and starts the
/// job. Otherwise it sits at [HomeReviewStage.idle] with a play button — press
/// it to run, press pause to stop, press play again to carry on from where it
/// got to.
/// "Carry on" is free rather than clever: fetching is cached, the book check is
/// instant, and the engine pass already skips games it has finished — all
/// except the ones the list still shows without mistake counts, which are
/// looked at again however long ago they were mined (see
/// [_needsEnginePassFor]).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../models/engine_settings.dart';
import '../../../services/games_library/games_library_service.dart'
    show GamesLibraryService, GamesPlatform;
import '../../../utils/log.dart';
import '../../tactics/services/mining_settings.dart';
import '../../tactics/services/tactics_import_coordinator.dart';
import '../../../utils/safe_change_notifier.dart';
import '../controllers/recent_games_controller.dart';
import 'games_window.dart';

enum HomeReviewStage {
  /// Never started, or finished and reset — the play button's resting state.
  idle,
  fetching,
  openings,
  reviewing,

  /// Stopped by the user with work left. Pressing play resumes.
  paused,
  done,
  failed;

  bool get isBusy => switch (this) {
    HomeReviewStage.fetching ||
    HomeReviewStage.openings ||
    HomeReviewStage.reviewing => true,
    _ => false,
  };

  /// The progress line. Spelled out — "Mining" alone doesn't tell you what is
  /// eating the CPU.
  String get label => switch (this) {
    HomeReviewStage.idle => 'Ready — press play to review your games',
    HomeReviewStage.fetching => 'Getting your recent games…',
    HomeReviewStage.openings => 'Checking your games against your books…',
    HomeReviewStage.reviewing => 'Looking for your mistakes…',
    HomeReviewStage.paused => 'Paused',
    HomeReviewStage.done => 'Review complete',
    HomeReviewStage.failed => 'Review failed',
  };
}

class HomeReviewRunner extends ChangeNotifier with SafeChangeNotifier {
  HomeReviewRunner({
    required this._games,
    required TacticsImportCoordinator importCoordinator,
    required this._lichessUsername,
    required this._chesscomUsername,
    GamesWindowSettings? windowSettings,
    MiningSettings? miningSettings,
    EngineSettings? engine,
  }) : _import = importCoordinator,
       _windowSettings = windowSettings ?? GamesWindowSettings.instance,
       _mining = miningSettings ?? MiningSettings.instance,
       _engine = engine ?? EngineSettings.instance;

  final RecentGamesController _games;
  final TacticsImportCoordinator _import;
  final String? Function() _lichessUsername;
  final String? Function() _chesscomUsername;
  final GamesWindowSettings _windowSettings;
  final MiningSettings _mining;
  final EngineSettings _engine;

  HomeReviewStage _stage = HomeReviewStage.idle;
  String? _detail;
  bool _paused = false;

  /// The pipeline in flight — including one that has been asked to pause and
  /// is still winding down. [_stage] cannot stand in for this: pause reports
  /// itself the instant the button is pressed, while the engine keeps grinding
  /// out the game it is in the middle of.
  Future<void>? _run;

  /// A play press that arrived while the previous run was still stopping,
  /// carried out as soon as it lets go.
  bool _resumeQueued = false;

  /// `[%eval]`-annotated movetexts reported by the engine pass since the last
  /// flush, keyed by games-library identity. Held rather than written one by
  /// one because the write patches a whole cache file — see
  /// [_flushAnnotations].
  final Map<String, String> _annotations = {};

  HomeReviewStage get stage => _stage;

  /// Extra context for the current stage (an error message, or which site is
  /// being reviewed), or null.
  String? get detail => _detail;

  bool get isRunning => _stage.isBusy;

  /// Whether pressing play would carry on an interrupted review rather than
  /// start a fresh one. Only affects wording — [start] does the same thing.
  bool get canResume => _stage == HomeReviewStage.paused;

  /// Whether the review has a source to pull from at all.
  bool get hasAnySource =>
      (_lichessUsername()?.trim().isNotEmpty ?? false) ||
      (_chesscomUsername()?.trim().isNotEmpty ?? false);

  /// How much of the machine this review is allowed to use, for the strip that
  /// says so out loud.
  int get cores => _engine.workers;
  int get depth => _mining.depth;

  void _to(HomeReviewStage stage, {String? detail}) {
    _stage = stage;
    _detail = detail;
    notifyListeners();
  }

  /// Run (or resume) the review.
  ///
  /// Two kinds of second press, told apart by [_paused]:
  ///
  /// * **While it is running** — the user pressed play twice. Ignored rather
  ///   than queued; the returned future is the run already going.
  /// * **While it is stopping** — pause reports itself immediately, so the
  ///   button reads "Resume" for the seconds the engine needs to finish the
  ///   game it is in. Starting a second pipeline there is what used to happen,
  ///   and both died: the new one found the coordinator still busy and refused,
  ///   which set [_paused] again and stopped the old one too. Press Resume too
  ///   soon and nothing happened. It is queued behind the run instead.
  Future<void> start({bool checkForNewGames = false}) async {
    final inFlight = _run;
    if (inFlight != null) {
      if (_paused) _resumeQueued = true;
      return inFlight;
    }
    final run = _drive(checkForNewGames: checkForNewGames);
    _run = run;
    try {
      await run;
    } finally {
      _run = null;
    }
    if (_resumeQueued) {
      _resumeQueued = false;
      await start();
    }
  }

  Future<void> _drive({required bool checkForNewGames}) async {
    final resuming = _stage == HomeReviewStage.paused;
    _paused = false;
    // The engine pass scores every position it looks at; collect the series so
    // [_review] can put them in the games cache, where the viewer's graph
    // reads them instead of searching the same game again.
    _import.onGameAnnotated = (dedupKey, movetext) {
      _annotations[dedupKey] = movetext;
      // The card wants the moves behind its counts as soon as they exist.
      unawaited(_games.applyAnnotatedMovetext(dedupKey, movetext));
    };
    try {
      _to(HomeReviewStage.fetching);
      // Whether this run needs to go and look depends on what it is for.
      //
      // A run with games still to analyse is carrying on with work already in
      // hand; the download cache (12 hours) is exactly right there, and
      // pressing play twice twenty seconds apart should not ask Lichess for
      // the same games twice.
      //
      // A run with *nothing* left to analyse is the other question entirely —
      // it is the user asking whether anything new has been played, which is
      // what the button says when it reads "Check for new games". Served from
      // the cache it cannot answer: the run reviews the games it already
      // reviewed and reports that you are all caught up, an hour after you
      // played three more. So that run fetches.
      // Startup explicitly asks for a fresh check even when cached games are
      // still waiting for the engine. Otherwise a backlog could postpone
      // discovering newly played games until a later launch.
      final lookingForNewGames =
          checkForNewGames || (!resuming && _unanalysedCount() == 0);
      await _games.refresh(force: lookingForNewGames);
      if (_stopHere()) return;

      // Cheap (no engine) and it changes whenever a book is edited, so it runs
      // before the long stage — the verdicts are on screen within a second.
      _to(HomeReviewStage.openings);
      await _games.recomputeDeviations();
      if (_stopHere()) return;

      _to(HomeReviewStage.reviewing);
      await _review();
      if (_stopHere()) return;

      _to(HomeReviewStage.done);
    } catch (e) {
      if (_paused) {
        _to(HomeReviewStage.paused);
      } else {
        _to(HomeReviewStage.failed, detail: '$e');
      }
    } finally {
      _import.onGameAnnotated = null;
      _annotations.clear();
    }
  }

  /// Stop after the game in flight. Whatever has been reviewed stays reviewed,
  /// and [start] carries on from there.
  void pause() {
    // Also cancels a resume queued behind a run that is still stopping —
    // otherwise play-then-pause during the wind-down would resume anyway.
    _resumeQueued = false;
    if (!isRunning) return;
    _paused = true;
    _import.cancelImport();
    _to(HomeReviewStage.paused);
  }

  /// Back to the resting state (e.g. after the window changed, so "complete"
  /// would be a lie about a different set of games).
  void reset() {
    if (_run != null) return;
    _to(HomeReviewStage.idle);
  }

  /// Games on the list that the engine has not reported counts for — the
  /// same tally the strip puts in its headline and on the play button.
  int _unanalysedCount() =>
      _games.games.where((g) => g.meWhite != null && g.summary == null).length;

  bool _stopHere() {
    if (!_paused) return false;
    _to(HomeReviewStage.paused);
    return true;
  }

  static GamesPlatform _platformOf(TacticsImportSource source) =>
      source == TacticsImportSource.lichess
      ? GamesPlatform.lichess
      : GamesPlatform.chesscom;

  /// The loaded games for one site, as a multi-game PGN. Empty when the list
  /// has none from there.
  String _fetchedPgnsFor(TacticsImportSource source) {
    final platform = _platformOf(source);
    return _games.games
        .where((g) => g.platform == platform)
        .map((g) => g.record.pgn.trim())
        .join('\n\n');
  }

  /// The games this site owes the engine something for, handed to the pass as
  /// "look at these whatever you think you know".
  ///
  /// Two debts, and a game marked analyzed can carry either. No mistake counts:
  /// a game mined by an older build was never asked for them, so the pass's own
  /// skip-what's-analyzed filter would walk straight past it and the count on
  /// the button would never move — this is what makes "Resume engine analysis
  /// (12)" analyse twelve games. No stored `[%eval]` series: the pass used to
  /// compute every score in the game and keep only the counts, so those games
  /// open on a blank graph until one pass writes the scores down. Re-mining
  /// them is what fills the graph in, and it happens once — the run stores the
  /// series, and [RecentGame.hasStoredEvals] is true on the next load.
  Set<String> _needsEnginePassFor(TacticsImportSource source) {
    final platform = _platformOf(source);
    return {
      for (final g in _games.games)
        if (g.platform == platform &&
            g.meWhite != null &&
            (g.summary == null || !g.hasStoredEvals))
          g.record.dedupKey,
    };
  }

  /// The engine pass, per configured site — the coordinator refuses concurrent
  /// runs, so these cannot be parallel.
  Future<void> _review() async {
    await _windowSettings.ensureLoaded();
    await _mining.ensureLoaded();
    final window = _windowSettings.window;
    final sources = <(TacticsImportSource, String)>[
      if (_lichessUsername()?.trim().isNotEmpty ?? false)
        (TacticsImportSource.lichess, _lichessUsername()!.trim()),
      if (_chesscomUsername()?.trim().isNotEmpty ?? false)
        (TacticsImportSource.chessCom, _chesscomUsername()!.trim()),
    ];
    for (final (source, username) in sources) {
      if (_paused) return;
      _to(
        HomeReviewStage.reviewing,
        detail: source == TacticsImportSource.lichess ? 'Lichess' : 'Chess.com',
      );
      // The fetch stage already downloaded these games; hand them straight to
      // the engine pass rather than asking the site for them a second time.
      // Empty (a failed or filtered-out fetch) falls back to fetching, so the
      // review still works when the list could not load.
      final fetched = _fetchedPgnsFor(source);
      final completed = await _import.import(
        source: source,
        pgnContent: fetched.isEmpty ? null : fetched,
        forceDedupKeys: _needsEnginePassFor(source),
        params: TacticsImportParams(
          username: username,
          mode: window.isGameCount
              ? TacticsImportMode.recent
              : TacticsImportMode.sinceDate,
          maxGames: window.gameLimit,
          since: window.cutoffFrom(DateTime.now()),
          depth: _mining.depth,
          cores: _engine.workers,
        ),
      );
      // Written whether or not the pass finished: every game it did get to
      // has its scores, and a stopped run must not throw them away any more
      // than it throws away the counts.
      await _flushAnnotations(_platformOf(source));
      // The pass can also be stopped from the puzzle panel's own status banner,
      // or refused because something else holds the coordinator. Either way it
      // did not finish, so this run is paused — carrying on to the next account
      // would start a fresh engine pass the user just stopped.
      if (!completed) {
        _paused = true;
        return;
      }
    }
  }

  /// Write the `[%eval]` series the pass produced into one site's games cache,
  /// so opening any of those games shows its graph without an engine pass.
  ///
  /// One batched patch per site rather than one per game: the write rewrites
  /// the whole cache file, so a per-game write would rewrite it once for every
  /// game in the window. Best-effort — the scores are a bonus on top of the
  /// counts, and a cache that cannot be written is not a reason to fail a
  /// review that otherwise worked.
  Future<void> _flushAnnotations(GamesPlatform platform) async {
    if (_annotations.isEmpty) return;
    // Only this site's games. The other site's are a different cache file and
    // are patched on their own turn, so taking the whole map here would drop
    // them on the floor.
    final mine = {
      for (final g in _games.games)
        if (g.platform == platform &&
            _annotations.containsKey(g.record.dedupKey))
          g.record.dedupKey: _annotations[g.record.dedupKey]!,
    };
    for (final key in mine.keys) {
      _annotations.remove(key);
    }
    if (mine.isEmpty) return;
    // Non-null whenever [mine] is: the rows it was built from are the ones
    // that name the file.
    final cachePath = _cachePathFor(platform);
    if (cachePath == null) return;
    try {
      await GamesLibraryService.patchGameMovetexts(
        cachePath: cachePath,
        movetextByDedupKey: mine,
      );
    } catch (e) {
      log.w('Could not store analysis in the games cache: $e');
    }
  }

  /// Where this site's games are cached, taken from the loaded rows — they
  /// were read from that file. Null when the list has none from there.
  String? _cachePathFor(GamesPlatform platform) {
    for (final g in _games.games) {
      if (g.platform == platform) return g.cachePath;
    }
    return null;
  }
}
