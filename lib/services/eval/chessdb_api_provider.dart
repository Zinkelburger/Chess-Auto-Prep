/// ChessDB cloud API client.
///
/// Two questions, two endpoints:
///   * `action=queryscore` — one number for the position (the eval chain).
///   * `action=queryall&json=1` — every move ChessDB knows, scored and ranked
///     (the mainline-book builder). One request answers a whole fan-out, so a
///     book build costs a request per *position*, not per move.
///
/// Endpoint base: `http://www.chessdb.cn/cdb.php`
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/fen_utils.dart';
import 'chessdb_score.dart';
import 'db_move_list.dart';
import 'eval_canonicalize.dart';
import 'external_eval_provider.dart';

const _defaultBaseUrl = 'http://www.chessdb.cn/cdb.php';
const _quotaDateKey = 'chessdb_api_quota_date';
const _quotaCountKey = 'chessdb_api_quota_count';

typedef ChessDbHttpFetch = Future<http.Response> Function(Uri uri);

/// Parse a queryscore response body into white-normalized cp.
///
/// Returns null on unknown / invalid / rate-limit responses.
EvalHit? parseChessDbQueryScoreBody(String body, String fen) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;

  if (trimmed.contains('unknown') ||
      trimmed.contains('invalid board') ||
      trimmed.toLowerCase().contains('rate limit') ||
      trimmed.toLowerCase().contains('too many')) {
    return null;
  }

  final isWhiteStm = isWhiteToMove(canonicalizeFen4(fen));

  // Plain-text: eval:123
  final evalMatch = RegExp(
    r'eval:\s*(-?\d+)',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (evalMatch != null) {
    final raw = int.parse(evalMatch.group(1)!);
    final mapped = mapChessDbApiScore(raw, isWhiteToMove: isWhiteStm);
    if (mapped == null) return null;
    final cp = mapped.$1;
    final mate = mapped.$2;
    return EvalHit(cp: cp, mate: mate, depth: 0);
  }

  // JSON: {"status":"ok","eval":123,...}
  try {
    final json = jsonDecode(trimmed);
    if (json is Map<String, dynamic>) {
      final status = json['status']?.toString() ?? '';
      if (status == 'unknown' || status == 'invalid board') return null;
      if (json.containsKey('eval')) {
        final raw = (json['eval'] as num).toInt();
        final mapped = mapChessDbApiScore(raw, isWhiteToMove: isWhiteStm);
        if (mapped == null) return null;
        final cp = mapped.$1;
        final mate = mapped.$2;
        final depth = (json['depth'] as num?)?.toInt() ?? 0;
        return EvalHit(cp: cp, mate: mate, depth: depth);
      }
    }
  } catch (_) {
    // Not JSON — fall through.
  }

  return null;
}

/// Map ChessDB raw score (STM) to white-normalized (cp, mate?).
(int cp, int? mate)? mapChessDbApiScore(
  int raw, {
  required bool isWhiteToMove,
}) {
  final decoded = mapChessDbRawScoreStm(raw);
  final whiteCp = isWhiteToMove ? decoded.stmCp : -decoded.stmCp;
  return (whiteCp, decoded.mate);
}

/// Parse a `queryall&json=1` body into a ranked move list.
///
/// Returns an empty list for `unknown`, an invalid board, a rate-limit reply,
/// or anything that is not the JSON shape this endpoint documents — a book
/// build treats "no moves" as the end of the book, so a garbled answer must
/// not read like a scored one.
List<DbMove> parseChessDbQueryAllBody(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return const [];

  final dynamic decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return const [];
  }
  if (decoded is! Map<String, dynamic>) return const [];
  if ((decoded['status']?.toString() ?? '') != 'ok') return const [];

  final rawMoves = decoded['moves'];
  if (rawMoves is! List) return const [];

  final moves = <DbMove>[];
  for (final entry in rawMoves) {
    if (entry is! Map<String, dynamic>) continue;
    final uci = entry['uci']?.toString() ?? '';
    final score = (entry['score'] as num?)?.toInt();
    if (uci.isEmpty || score == null) continue;
    final mapped = mapChessDbRawScoreStm(score);
    final note = entry['note']?.toString().trim();
    moves.add(
      DbMove(
        uci: uci,
        san: entry['san']?.toString() ?? '',
        stmCp: mapped.stmCp,
        mate: mapped.mate,
        rank: (entry['rank'] as num?)?.toInt(),
        note: (note == null || note.isEmpty) ? null : note,
      ),
    );
  }
  return DbMoveList.sorted(moves);
}

class ChessDbApiProvider implements ExternalEvalProvider, ExternalMoveProvider {
  final int dailyQuota;
  final int concurrency;
  final ChessDbHttpFetch? httpFetch;
  final SharedPreferences? prefsOverride;

  int _usedToday = 0;
  String _quotaDate = '';
  bool _quotaLoaded = false;
  int _inFlight = 0;
  final _waiters = <Completer<void>>[];

  // Rate-limit backoff: ChessDB has no published daily quota, only a request
  // rate. Rather than stop at a made-up ceiling, we run until the server
  // pushes back, then cool down for a growing window; after enough
  // consecutive limits we stand down for the rest of the day and let the
  // engine take over. Reset on any successful reply.
  //
  // For reference, measured 2026-08-25: 30 sequential `queryall` requests
  // spaced 1s apart all returned 200, median latency 0.84s. No throttling
  // was observed at that rate, so the backoff below has never actually been
  // seen to fire against the real server — treat its constants as a
  // precaution, not as a fitted model of anything.
  int _consecutiveLimits = 0;
  DateTime? _cooldownUntil;

  ChessDbApiProvider({
    this.dailyQuota = 5000,
    this.concurrency = 2,
    this.httpFetch,
    this.prefsOverride,
  });

  int get usedToday => _usedToday;
  int get quotaLimit => dailyQuota;
  bool get quotaRemaining => _usedToday < dailyQuota;

  /// True while the provider is backing off after server rate-limiting.
  /// The eval chain skips it (falling through to the engine) until this
  /// clears. Surfaced so the UI can say "ChessDB (rate-limited)".
  bool get isRateLimited {
    final until = _cooldownUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  Future<void> init() async {
    if (_quotaLoaded) return;
    final prefs = prefsOverride ?? await SharedPreferences.getInstance();
    final today = _todayKey();
    _quotaDate = prefs.getString(_quotaDateKey) ?? '';
    if (_quotaDate == today) {
      _usedToday = prefs.getInt(_quotaCountKey) ?? 0;
    } else {
      _usedToday = 0;
      _quotaDate = today;
      await prefs.setString(_quotaDateKey, today);
      await prefs.setInt(_quotaCountKey, 0);
    }
    _quotaLoaded = true;
  }

  Future<void> flushQuota() async {
    if (!_quotaLoaded) return;
    final prefs = prefsOverride ?? await SharedPreferences.getInstance();
    await prefs.setString(_quotaDateKey, _quotaDate);
    await prefs.setInt(_quotaCountKey, _usedToday);
  }

  @override
  Future<EvalLookupResult> lookup(String fen, {required int minDepth}) async {
    await init();
    if (!quotaRemaining || isRateLimited) return const EvalLookupResult.miss();

    await _acquireSlot();
    try {
      if (!quotaRemaining || isRateLimited) {
        return const EvalLookupResult.miss();
      }

      final board = Uri.encodeComponent(canonicalizeFen4(fen));
      final uri = Uri.parse('$_defaultBaseUrl?action=queryscore&board=$board');
      final fetch = httpFetch ?? http.get;
      final response = await fetch(uri).timeout(_requestTimeout);

      if (_isRateLimitResponse(response)) {
        _noteRateLimited();
        return const EvalLookupResult.miss();
      }

      final hit = parseChessDbQueryScoreBody(response.body, fen);
      if (hit == null) {
        // A clean "unknown"/miss is not rate-limiting — don't back off, but
        // don't reset the limit streak on it either.
        return const EvalLookupResult.miss();
      }

      // A real answer means we are not rate-limited: clear any backoff.
      _consecutiveLimits = 0;
      _cooldownUntil = null;

      if (hit.depth > 0 && hit.depth < minDepth) {
        return const EvalLookupResult.shallow();
      }

      _usedToday++;
      unawaited(flushQuota());
      return EvalLookupResult.found(hit);
    } catch (e) {
      if (kDebugMode) debugPrint('[ChessDbApiProvider] lookup failed: $e');
      return const EvalLookupResult.miss();
    } finally {
      _releaseSlot();
    }
  }

  /// Every move ChessDB knows from [fen], best first; empty on a miss.
  ///
  /// Shares the quota counter and rate-limit backoff with [lookup] — it is
  /// the same server and the same budget. Unlike [lookup] there is no depth
  /// gate: `queryall` reports no depth, and a book build wants the database's
  /// ranking whatever confidence sits behind it.
  @override
  Future<DbMoveList> lookupMoves(String fen) async {
    await init();
    if (!quotaRemaining) return DbMoveList.empty;

    final board = Uri.encodeComponent(canonicalizeFen4(fen));
    final uri = Uri.parse(
      '$_defaultBaseUrl?action=queryall&json=1&board=$board',
    );

    for (var attempt = 0; attempt < _bookRetries; attempt++) {
      if (!await _awaitCooldown()) return DbMoveList.empty;
      if (!quotaRemaining) return DbMoveList.empty;

      await _acquireSlot();
      final http.Response response;
      try {
        response = await (httpFetch ?? http.get)(uri).timeout(_requestTimeout);
      } catch (e) {
        if (kDebugMode) debugPrint('[ChessDbApiProvider] queryall failed: $e');
        return DbMoveList.empty;
      } finally {
        _releaseSlot();
      }

      // Being throttled is not an answer about the position — it is the
      // server asking for a pause. Take the pause and ask again rather than
      // reporting a miss the caller will answer with an engine search.
      if (_isRateLimitResponse(response)) {
        _noteRateLimited();
        continue;
      }

      _consecutiveLimits = 0;
      _cooldownUntil = null;

      final moves = parseChessDbQueryAllBody(response.body);
      if (moves.isEmpty) return DbMoveList.empty;

      _usedToday++;
      unawaited(flushQuota());
      return DbMoveList(moves: moves, source: DbMoveSource.chessDbApi);
    }

    return DbMoveList.empty;
  }

  /// Whether [response] is the server refusing to answer, as opposed to
  /// answering that it does not know the position.
  ///
  /// **Any non-200 status counts.** ChessDB reports a position it has never
  /// seen as `200` with `{"status":"unknown"}`, so a non-200 is never an
  /// answer about the position — it is a transport or server problem, and
  /// the two need opposite handling. Reading one as a miss is expensive in a
  /// way that is easy to overlook: the caller shrugs and asks the engine
  /// instead, so a run of them quietly stops the build being a ChessDB build
  /// at all, and says so nowhere.
  ///
  /// Checking only for 429 was too narrow to catch that. (It also made a
  /// Flutter test binding look exactly like a healthy miss:
  /// `TestWidgetsFlutterBinding` installs an `HttpOverrides` mock answering
  /// every request with an empty 400, which is why anything driving a real
  /// build headlessly has to clear `HttpOverrides.global` first.)
  bool _isRateLimitResponse(http.Response response) {
    if (response.statusCode != 200) return true;
    final body = response.body.toLowerCase();
    return body.contains('rate limit') || body.contains('too many');
  }

  /// Wait out an active cooldown, up to [_maxWaitForCooldown].
  ///
  /// Returns false when the provider has stood down for the day, or the wait
  /// would be longer than a caller should be asked to hold for.
  Future<bool> _awaitCooldown() async {
    final until = _cooldownUntil;
    if (until == null) return true;
    final remaining = until.difference(DateTime.now());
    if (remaining <= Duration.zero) return true;
    if (remaining > _maxWaitForCooldown) return false;
    await Future<void>.delayed(remaining);
    return true;
  }

  static const Duration _maxWaitForCooldown = Duration(seconds: 90);

  /// How long one HTTP request may take before it is abandoned.
  ///
  /// `package:http` has no default timeout, and both lookups run inside a
  /// [concurrency]-wide slot. A server that accepts the connection and then
  /// never answers therefore used to hold its slot for the life of the
  /// process: with the default two slots, two such requests wedged every
  /// later lookup behind a [Completer] that nothing would ever complete.
  /// Timing out is what lets the `finally` release the slot.
  ///
  /// Generous on purpose — this is the "it is never coming" bound, not a
  /// latency target. A slow answer is still an answer.
  static const Duration _requestTimeout = Duration(seconds: 20);

  /// Attempts a refused book lookup gets before giving up on the position.
  ///
  /// Worth retrying where a single eval is not: the caller's alternative is a
  /// full-depth engine search, which costs far more than sitting out a
  /// backoff — and answers a different question. Kept small (about 3s of
  /// waiting in total) so one unlucky position cannot walk the provider into
  /// its own [_standDownAfter] stand-down.
  static const int _bookRetries = 3;

  /// Record a rate-limit and extend the cooldown. Exponential in the number
  /// of consecutive limits (1s, 2s, 4s, …) capped at 60s; after
  /// [_standDownAfter] in a row, stand down for the rest of the day so the
  /// build stops hammering a server that has clearly cut us off.
  void _noteRateLimited() {
    _consecutiveLimits++;
    final now = DateTime.now();
    if (_consecutiveLimits >= _standDownAfter) {
      _cooldownUntil = DateTime(now.year, now.month, now.day + 1);
      return;
    }
    final backoffSeconds = (1 << (_consecutiveLimits - 1)).clamp(
      1,
      _maxBackoffSeconds,
    );
    _cooldownUntil = now.add(Duration(seconds: backoffSeconds));
  }

  static const int _standDownAfter = 6;
  static const int _maxBackoffSeconds = 60;

  Future<void> _acquireSlot() async {
    while (_inFlight >= concurrency) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _inFlight++;
  }

  void _releaseSlot() {
    _inFlight--;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }

  static String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
}
