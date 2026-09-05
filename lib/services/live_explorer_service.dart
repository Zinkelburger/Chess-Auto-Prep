/// Live Lichess Opening Explorer lookups for the **user-facing** explorer
/// panel only.
///
/// This is deliberately separate from the move-generation pipeline: the
/// generator must never hit the Lichess Explorer API (it would exhaust the
/// one-request-at-a-time rate limit), so it uses local frequency maps
/// instead. This service is what the human sees while browsing — one
/// position at a time, debounced, and cached.
///
/// Responsibilities:
///   • Debounce rapid position changes (scrubbing) so only the latest FEN
///     actually fetches — on the *leading* edge, so a single click after a
///     quiet spell starts its request at once and only a burst waits.
///   • Coalesce in-flight requests: a response for a superseded FEN is
///     dropped rather than shown.
///   • Cache results in the app-wide [ExplorerCacheService] store, so
///     revisiting a position is instant and API-free — and a position the
///     candidate service or a build session already fetched is a hit here.
///   • Stop asking past the depth the database answers: beyond [maxPly], or
///     after [emptyStreakLimit] consecutive empty answers down a line, deeper
///     positions are reported empty without a request (lila's `movesAway`).
///   • Carry the previous position's response through the loading state, so
///     the panel can hold the old table on screen (dimmed) instead of
///     blanking to a spinner — the trick that makes lichess.org's explorer
///     feel instant even when the round trip is not.
///   • Surface a simple load state (idle/loading/data/error/rateLimited/
///     authRequired) for the UI, honouring the client's 429 backoff window
///     and Lichess's 2026 requirement that Explorer callers be logged in.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../features/coverage/services/coverage_service.dart'
    show LichessDatabase;
import '../models/explorer_response.dart';
import '../utils/chess_utils.dart' show uciToSan;
import '../utils/fen_utils.dart';
import 'explorer_cache_service.dart';
import 'lichess_api_client.dart';
import 'lichess_auth_service.dart';
import 'master_games/master_games_db.dart';
import 'master_games/master_games_service.dart';

enum ExplorerStatus { idle, loading, data, error, rateLimited, authRequired }

/// Immutable snapshot of the explorer panel's current lookup.
@immutable
class ExplorerState {
  final ExplorerStatus status;

  /// FEN this state describes (null only for [ExplorerStatus.idle]).
  final String? fen;

  /// Parsed response. For [ExplorerStatus.data] it describes [fen]; for
  /// [ExplorerStatus.loading] it is the *previous* position's response, kept
  /// so the UI has something truthful to show while the new one lands. Check
  /// [isStale] before treating it as this position's data.
  final ExplorerResponse? data;

  const ExplorerState._(this.status, {this.fen, this.data});

  const ExplorerState.idle() : this._(ExplorerStatus.idle);

  /// Loading [fen], optionally still holding [previous] — the response for
  /// the position we are leaving — for the panel to keep on screen.
  const ExplorerState.loading(String fen, {ExplorerResponse? previous})
    : this._(ExplorerStatus.loading, fen: fen, data: previous);
  ExplorerState.data(ExplorerResponse response)
    : this._(ExplorerStatus.data, fen: response.fen, data: response);
  const ExplorerState.error(String fen)
    : this._(ExplorerStatus.error, fen: fen);
  const ExplorerState.rateLimited(String fen)
    : this._(ExplorerStatus.rateLimited, fen: fen);

  /// Lichess needs an account before it will answer Explorer queries.
  const ExplorerState.authRequired(String fen)
    : this._(ExplorerStatus.authRequired, fen: fen);

  /// [data] belongs to a position we have already left — show it, but do not
  /// let it be clicked: its moves are not legal in [fen].
  bool get isStale => status == ExplorerStatus.loading && data != null;
}

/// Query parameters that identify a distinct explorer result.
@immutable
class ExplorerQuery {
  final LichessDatabase database;
  final Set<String> speeds;
  final Set<String> ratings;

  /// TWIC only: count classical over-the-board games and nothing else.  The
  /// corpus is over half online blitz, so this is the one filter the local
  /// database needs.
  final bool classicalOnly;

  const ExplorerQuery({
    required this.database,
    this.speeds = const {'blitz', 'rapid', 'classical'},
    this.ratings = const {'2000', '2200', '2500'},
    this.classicalOnly = false,
  });

  bool get useMasters => database == LichessDatabase.masters;

  /// Answered from the master-games database on this machine, not Lichess.
  bool get isLocal => database == LichessDatabase.twic;
  String get speedsParam => (speeds.toList()..sort()).join(',');
  String get ratingsParam => (ratings.toList()..sort()).join(',');

  /// The same query as the shared cache keys it.
  ExplorerSourceConfig get source => ExplorerSourceConfig(
    useMasters: useMasters,
    speeds: speedsParam,
    ratings: ratingsParam,
  );
}

class LiveExplorerService {
  LiveExplorerService({
    LichessApiClient? client,
    ExplorerCacheService? cache,
    bool Function()? isLoggedIn,
    MasterGamesDb? Function()? localDb,
    this.debounce = const Duration(milliseconds: 250),
    this.maxPly = 50,
    this.emptyStreakLimit = 3,
  }) : _client = client ?? LichessApiClient.instance,
       _cache = cache ?? ExplorerCacheService.instance,
       _isLoggedIn =
           isLoggedIn ?? (() => LichessAuthService.instance.isLoggedIn),
       _localDb = localDb ?? (() => MasterGamesService.instance.db);

  final LichessApiClient _client;

  /// The master-games database on this machine, looked up per request so a
  /// database that opens after this service was built is still found.
  final MasterGamesDb? Function() _localDb;

  /// How many games the local database lists for a position.  Lila's
  /// masters list is fifteen; the book remembers up to three ids per move,
  /// so the strongest move or two fill most of it.
  static const int localTopGames = 12;

  /// Response store shared with every other explorer consumer.  This
  /// service fetches through its own client (which owns the politeness gap
  /// and 429 backoff) and only uses the store as a store.
  final ExplorerCacheService _cache;

  /// Ply past which the explorer is not asked at all: the database has
  /// nothing that deep and lichess-mobile stops at the same depth.
  final int maxPly;

  /// After this many consecutive empty answers going deeper down a line,
  /// deeper positions are reported empty without a request.  Stepping back
  /// to a shallower ply resets the count.
  final int emptyStreakLimit;

  /// Whether a Lichess account is connected. Injected so tests need no
  /// singleton auth state.
  final bool Function() _isLoggedIn;

  final Duration debounce;

  /// UI listens to this for spinner / rows / error banner.
  final ValueNotifier<ExplorerState> state = ValueNotifier(
    const ExplorerState.idle(),
  );

  Timer? _debounceTimer;

  /// Consecutive empty answers on the way down the current line, and the
  /// ply of the last one — lila's `movesAway`.
  int _emptyStreak = 0;
  int _emptyStreakPly = -1;

  /// The line the empty run was seen on: the move path at the answer that
  /// started it.  The run is evidence about positions that *continue* that
  /// line and nothing else — without this, three dead answers at plies 30-32
  /// of one obscure line silence every position past ply 32 anywhere else,
  /// until the user steps back above ply 32.
  List<String> _emptyStreakPath = const [];

  /// When [request] was last called, so a lone click can skip the debounce
  /// while a burst still collapses into one fetch.
  DateTime? _lastRequestAt;

  /// Monotonic request id; a completed fetch only wins if it is still the
  /// latest requested lookup (coalescing).
  int _requestSeq = 0;

  /// Request explorer data for [fen]. Debounced and coalesced; the result is
  /// delivered via [state]. A cache hit resolves synchronously.
  ///
  /// The shared store keys positions by their first four FEN fields: the
  /// move counters do not change which games reached a position, and
  /// Lichess ignores them, so the same position down two move orders is one
  /// entry.
  ///
  /// [movePath] is the line [fen] sits on, and scopes the empty-run cutoff to
  /// that line.  A caller with no path in hand may omit it; the cutoff then
  /// applies by depth alone, as it did before paths were passed.
  void request(
    String fen,
    ExplorerQuery query, {
    List<String> movePath = const [],
  }) {
    _debounceTimer?.cancel();

    if (query.isLocal) {
      // An indexed lookup on this machine: no debounce, no cache, no login.
      _requestSeq++;
      _lastRequestAt = DateTime.now();
      state.value = ExplorerState.data(
        _localResponse(fen, classicalOnly: query.classicalOnly),
      );
      return;
    }

    final now = DateTime.now();
    final wasQuiet =
        _lastRequestAt == null || now.difference(_lastRequestAt!) >= debounce;
    _lastRequestAt = now;

    final cached = _cache.peek(fen, query.source);
    if (cached != null) {
      // Short-circuit — no network, no spinner.
      _requestSeq++; // invalidate any in-flight fetch
      _noteAnswer(fen, cached, movePath);
      state.value = ExplorerState.data(cached);
      return;
    }

    if (_beyondReach(fen, movePath)) {
      _requestSeq++;
      // No games that deep — reported without a request.
      state.value = ExplorerState.data(
        ExplorerResponse(fen: fen, moves: const [], totalGames: 0),
      );
      return;
    }

    // Lichess rejects anonymous Explorer calls outright, so don't spend a
    // round trip discovering that — say what is missing straight away.
    if (!_isLoggedIn()) {
      _requestSeq++;
      state.value = ExplorerState.authRequired(fen);
      return;
    }

    final seq = ++_requestSeq;
    // Hand the outgoing response to the loading state so the panel keeps the
    // old table on screen rather than collapsing to a spinner.
    state.value = ExplorerState.loading(fen, previous: state.value.data);

    if (wasQuiet) {
      // Leading edge: one click after a pause pays the round trip and nothing
      // else. Only while positions are still arriving does the timer take over
      // and let the burst settle on its last FEN.
      unawaited(_fetch(fen, query, seq, movePath));
    } else {
      _debounceTimer = Timer(debounce, () => _fetch(fen, query, seq, movePath));
    }
  }

  Future<void> _fetch(
    String fen,
    ExplorerQuery query,
    int seq,
    List<String> movePath,
  ) async {
    final response = await _client.fetchExplorer(
      fen,
      speeds: query.speedsParam,
      ratings: query.ratingsParam,
      useMasters: query.useMasters,
    );

    // Superseded by a newer request — drop this result.
    if (seq != _requestSeq) return;

    if (response == null) {
      state.value = _client.explorerAuthRequired
          ? ExplorerState.authRequired(fen)
          : _client.isBackingOff
          ? ExplorerState.rateLimited(fen)
          : ExplorerState.error(fen);
      return;
    }

    _cache.put(fen, query.source, response);
    _noteAnswer(fen, response, movePath);
    state.value = ExplorerState.data(response);
  }

  /// The local book's answer for [fen], in the shape the panel draws.
  ///
  /// Moves come from the book rows (classical-only rows when asked, with
  /// moves no classical game played dropped); the games are the strongest
  /// citation of each move, then the most recent game of each, strongest
  /// first and never twice.  A missing database answers as an empty
  /// position rather than an error: the panel's own source picker only
  /// offers TWIC when there is one.
  ExplorerResponse _localResponse(String fen, {required bool classicalOnly}) {
    final db = _localDb();
    if (db == null) {
      return ExplorerResponse(fen: fen, moves: const [], totalGames: 0);
    }
    List<BookMove> rows;
    try {
      rows = db.bookMoves(fen);
    } catch (_) {
      rows = const [];
    }
    if (classicalOnly) {
      rows = [for (final r in rows) ?r.classicalOnly]
        ..sort((a, b) => b.games.compareTo(a.games));
    }
    final total = rows.fold(0, (n, r) => n + r.games);
    final moves = [
      for (final r in rows)
        ExplorerMove(
          san: uciToSan(fen, r.uci),
          uci: r.uci,
          white: r.whiteWins,
          draws: r.draws,
          black: r.blackWins,
          playRate: total == 0 ? 0 : r.games / total * 100,
        ),
    ];

    final games = <ExplorerGame>[];
    final seen = <int>{};
    void add(int id, String san) {
      if (id == 0 || games.length >= localTopGames || !seen.add(id)) return;
      final g = db.game(id);
      if (g == null) return;
      games.add(_localGame(g, san));
    }

    for (final r in rows) {
      add(r.citeGameId, uciToSan(fen, r.uci));
    }
    for (final r in rows) {
      add(r.recentGameId, uciToSan(fen, r.uci));
    }
    games.sort((a, b) => b.topElo.compareTo(a.topElo));

    return ExplorerResponse(
      fen: fen,
      moves: moves,
      totalGames: total,
      white: rows.fold<int>(0, (n, r) => n + r.whiteWins),
      draws: rows.fold<int>(0, (n, r) => n + r.draws),
      black: rows.fold<int>(0, (n, r) => n + r.blackWins),
      topGames: games,
    );
  }

  static ExplorerGame _localGame(MasterGame g, String san) {
    final parts = g.date.split('.');
    return ExplorerGame(
      id: '${g.id}',
      source: ExplorerGameSource.twic,
      white: g.white,
      black: g.black,
      whiteElo: g.whiteElo,
      blackElo: g.blackElo,
      result: g.result,
      year: parts.isEmpty ? null : int.tryParse(parts[0]),
      month: parts.length < 2 ? null : int.tryParse(parts[1]),
      event: g.event,
      san: san,
    );
  }

  /// Whether [fen] is deeper than the database answers: past [maxPly], or
  /// deeper than a run of [emptyStreakLimit] empty answers *on its own line*.
  bool _beyondReach(String fen, List<String> movePath) {
    final ply = plyFromFen(fen);
    if (ply >= maxPly) return true;
    return _emptyStreak >= emptyStreakLimit &&
        ply > _emptyStreakPly &&
        _continuesStreakLine(movePath);
  }

  /// Whether [movePath] plays on past where the empty run was seen.  An empty
  /// [_emptyStreakPath] — a caller that passes no path — is a prefix of
  /// everything, which is the old depth-only behaviour.
  bool _continuesStreakLine(List<String> movePath) {
    final prefix = _emptyStreakPath;
    if (movePath.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (movePath[i] != prefix[i]) return false;
    }
    return true;
  }

  /// Track consecutive empty answers going deeper; any games, or a step back
  /// up the line, resets the run.
  void _noteAnswer(String fen, ExplorerResponse response, List<String> path) {
    final ply = plyFromFen(fen);
    if (response.moves.isNotEmpty ||
        ply <= _emptyStreakPly ||
        !_continuesStreakLine(path)) {
      _emptyStreak = 0;
      _emptyStreakPly = -1;
      _emptyStreakPath = const [];
    }
    if (response.moves.isEmpty) {
      // The first empty answer fixes the line the run is about; later ones
      // extend it without narrowing it to their own deeper path.
      if (_emptyStreak == 0) _emptyStreakPath = List.unmodifiable(path);
      _emptyStreak++;
      _emptyStreakPly = ply;
    }
  }

  /// Clear the panel back to idle (e.g. when the explorer is hidden).
  void reset() {
    _debounceTimer?.cancel();
    _lastRequestAt = null;
    _requestSeq++;
    _emptyStreak = 0;
    _emptyStreakPly = -1;
    _emptyStreakPath = const [];
    state.value = const ExplorerState.idle();
  }

  void dispose() {
    _debounceTimer?.cancel();
    state.dispose();
  }

  @visibleForTesting
  static void clearCacheForTest() => ExplorerCacheService.instance.clear();
}
