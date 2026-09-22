/// Centralised HTTP client for all Lichess / Lichess Explorer API calls.
///
/// Handles:
///   • Persistent TCP connections (keep-alive) to avoid per-request TLS overhead
///   • A small minimum gap between requests to stay polite to the API
///   • 429 detection with exponential backoff (60 s, 120 s, 240 s …)
///   • Automatic auth-header injection
///   • Configurable retry on transient errors
///   • Centralised Lichess Explorer response parsing via [fetchExplorer]
///
/// Main-thread code uses the singleton: `LichessApiClient.instance`.
/// Isolate code creates a disposable instance via
/// `LichessApiClient.withToken(token)` and calls [close] when finished.
library;

import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/explorer_response.dart';
import 'lichess_auth_service.dart';

/// How long [_waitForSlot] held a request back, for the profiling log.
typedef _SlotWait = ({int backoffMs, int politenessMs});

class LichessApiClient {
  // ── Singleton (main thread) ─────────────────────────────────────────

  /// Application-wide shared instance (main thread).
  static final LichessApiClient instance = LichessApiClient._internal();

  /// Create an independent instance (unit tests only). For isolate use, call
  /// the public [LichessApiClient.withToken] constructor instead.
  @visibleForTesting
  LichessApiClient.fresh() : this._internal();

  LichessApiClient._internal()
    : _httpClient = http.Client(),
      _authToken = null,
      _useAuthService = true;

  /// Create a standalone instance for use inside a Dart [Isolate].
  ///
  /// Owns its own [http.Client] and rate-limit state.  Call [close] when
  /// done to release the TCP connection pool.
  LichessApiClient.withToken(String? token, {http.Client? client})
    : _httpClient = client ?? http.Client(),
      _authToken = token,
      _useAuthService = false;

  // ── Configuration ───────────────────────────────────────────────────

  static const Duration politenessDelay = Duration(milliseconds: 100);
  static const int defaultMaxRetries = 3;
  static const int _baseBackoffSeconds = 60;

  /// Pause before retrying a request that failed with a transport error.
  static const Duration _transientRetryDelay = Duration(seconds: 2);

  static const String _explorerHost = 'https://explorer.lichess.ovh';
  static const String _siteHost = 'https://lichess.org';

  // ── State ───────────────────────────────────────────────────────────

  final http.Client _httpClient;
  final _closing = Completer<void>();
  bool _closed = false;

  void _checkOpen() {
    if (_closed) throw StateError('Lichess client is closed');
  }

  Future<T> _whileOpen<T>(Future<T> operation) async {
    _checkOpen();
    final result = await Future.any([
      operation,
      _closing.future.then<T>(
        (_) => throw StateError('Lichess client is closed'),
      ),
    ]);
    _checkOpen();
    return result;
  }

  Future<void> _delay(Duration duration) async {
    _checkOpen();
    final elapsed = Completer<void>();
    final timer = Timer(duration, elapsed.complete);
    try {
      await _whileOpen(elapsed.future);
    } finally {
      timer.cancel();
    }
  }

  final String? _authToken;
  final bool _useAuthService;

  DateTime _earliestNextRequest = DateTime(0);
  DateTime _lastRequestTime = DateTime(0);
  bool _profilingEnabled = false;
  void Function(String message)? _profilingLogger;

  bool _explorerAuthRequired = false;

  /// Whether the client is currently in a 429-backoff window.
  bool get isBackingOff => DateTime.now().isBefore(_earliestNextRequest);

  /// Whether Lichess rejected the last Explorer call for want of an account.
  ///
  /// Lichess put the opening explorer behind a login in 2026 (anti-abuse):
  /// anonymous requests to `explorer.lichess.ovh` return 401, and the API
  /// spec now declares `security: OAuth2` on every Explorer endpoint. This
  /// lets callers prompt for login instead of reporting a dead network.
  /// Set by [fetchExplorer] on 401/403, cleared by its next success.
  bool get explorerAuthRequired => _explorerAuthRequired;

  /// Enable/disable detailed per-request timing diagnostics.
  ///
  /// When enabled, timings include rate-limit waits, header resolution,
  /// network time, JSON decode, and model parsing.
  void configureProfiling({
    required bool enabled,
    void Function(String message)? logger,
  }) {
    _profilingEnabled = enabled;
    _profilingLogger = logger;
  }

  void _profile(String message) {
    if (!_profilingEnabled) return;
    final line = '[LichessProfile] $message';
    final logger = _profilingLogger;
    if (logger != null) {
      logger(line);
    } else if (kDebugMode) {
      debugPrint(line);
    }
  }

  // ── Headers ─────────────────────────────────────────────────────────

  Future<Map<String, String>> _resolveHeaders([
    Map<String, String>? extra,
  ]) async {
    if (_useAuthService) {
      return LichessAuthService.instance.getHeaders(extra);
    }
    return {
      ...?extra,
      if (_authToken != null) 'Authorization': 'Bearer $_authToken',
    };
  }

  // ── Rate-limit gate ─────────────────────────────────────────────────

  Future<_SlotWait> _waitForSlot() async {
    _checkOpen();
    var backoffMs = 0;
    var politenessMs = 0;

    // Honour any active 429 backoff window.
    final now = DateTime.now();
    if (now.isBefore(_earliestNextRequest)) {
      final wait = _earliestNextRequest.difference(now);
      backoffMs = wait.inMilliseconds;
      if (kDebugMode) {
        debugPrint('[LichessAPI] Backoff active — waiting ${wait.inSeconds}s');
      }
      await _delay(wait);
    }

    // Polite inter-request delay.
    final gap = DateTime.now().difference(_lastRequestTime);
    if (gap < politenessDelay) {
      final wait = politenessDelay - gap;
      politenessMs = wait.inMilliseconds;
      await _delay(wait);
    }
    _lastRequestTime = DateTime.now();
    return (backoffMs: backoffMs, politenessMs: politenessMs);
  }

  void _handle429(int attempt, int maxRetries, http.Response response) {
    final backoff = _baseBackoffSeconds * (1 << attempt);
    _earliestNextRequest = DateTime.now().add(Duration(seconds: backoff));
    if (kDebugMode) {
      debugPrint(
        '[LichessAPI] 429 — backing off ${backoff}s  '
        '(attempt ${attempt + 1}/$maxRetries)  '
        'Retry-After: ${response.headers['retry-after'] ?? 'none'}',
      );
    }
  }

  // ── Public API ──────────────────────────────────────────────────────

  /// HTTP GET with automatic rate-limiting and retries.
  ///
  /// Returns the [http.Response] on success (any non-429 status code).
  /// Returns `null` only when all retry attempts are exhausted.
  Future<http.Response?> get(
    Uri url, {
    Map<String, String>? extraHeaders,
    int maxRetries = defaultMaxRetries,
  }) => _sendWithRetries(
    'GET',
    extraHeaders: extraHeaders,
    maxRetries: maxRetries,
    send: (headers) => _httpClient.get(url, headers: headers),
  );

  /// HTTP POST with automatic rate-limiting and retries.
  ///
  /// Returns the [http.Response] on success (any non-429 status code).
  /// Returns `null` only when all retry attempts are exhausted.
  Future<http.Response?> post(
    Uri url, {
    Object? body,
    Map<String, String>? extraHeaders,
    int maxRetries = defaultMaxRetries,
  }) => _sendWithRetries(
    'POST',
    extraHeaders: extraHeaders,
    maxRetries: maxRetries,
    send: (headers) => _httpClient.post(url, headers: headers, body: body),
  );

  /// The retry loop shared by every verb: wait for a slot, resolve headers,
  /// [send], back off on 429 and sleep briefly on a transport error.  Null
  /// once `maxRetries + 1` attempts are spent.  [method] only labels the
  /// profiling log.
  Future<http.Response?> _sendWithRetries(
    String method, {
    required Map<String, String>? extraHeaders,
    required int maxRetries,
    required Future<http.Response> Function(Map<String, String> headers) send,
  }) async {
    final totalAttempts = maxRetries + 1;
    final opSw = Stopwatch()..start();
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      final attemptSw = Stopwatch()..start();
      final waited = await _waitForSlot();
      final afterWaitMs = attemptSw.elapsedMilliseconds;

      try {
        final headerSw = Stopwatch()..start();
        final headers = await _whileOpen(_resolveHeaders(extraHeaders));
        final headerMs = headerSw.elapsedMilliseconds;

        final netSw = Stopwatch()..start();
        _checkOpen();
        final response = await _whileOpen(send(headers));
        final netMs = netSw.elapsedMilliseconds;
        _profile(
          '$method attempt=${attempt + 1}/$totalAttempts '
          'status=${response.statusCode} '
          'wait=${afterWaitMs}ms(backoff=${waited.backoffMs}ms,'
          'polite=${waited.politenessMs}ms) '
          'headers=${headerMs}ms net=${netMs}ms '
          'attemptTotal=${attemptSw.elapsedMilliseconds}ms',
        );

        if (response.statusCode == 429) {
          _handle429(attempt, maxRetries, response);
          if (attempt < maxRetries) continue;
          _profile(
            '$method exhausted after 429 '
            'total=${opSw.elapsedMilliseconds}ms',
          );
          return null;
        }

        _profile('$method done total=${opSw.elapsedMilliseconds}ms');
        return response;
      } catch (e) {
        if (_closed) rethrow;
        _profile(
          '$method error attempt=${attempt + 1}/$totalAttempts '
          'elapsed=${attemptSw.elapsedMilliseconds}ms err=$e',
        );
        if (kDebugMode) {
          debugPrint('[LichessAPI] $method error (attempt ${attempt + 1}): $e');
        }
        if (attempt < maxRetries) {
          await _delay(_transientRetryDelay);
          _profile(
            '$method retry sleep=${_transientRetryDelay.inMilliseconds}ms',
          );
          continue;
        }
        _profile('$method failed total=${opSw.elapsedMilliseconds}ms');
        return null;
      }
    }
    return null;
  }

  // ── Lichess Explorer convenience ─────────────────────────────────────

  /// Fetch and parse a Lichess Explorer response for [fen].
  ///
  /// Returns a fully-parsed [ExplorerResponse] on success, or `null` when
  /// the request fails or all retries are exhausted.  Rate-limiting,
  /// retries, and auth are handled by [get].
  ///
  /// When [useMasters] is true, queries the masters database (titled player
  /// OTB games) instead of the regular Lichess database.  The masters
  /// endpoint ignores speed/rating filters.
  Future<ExplorerResponse?> fetchExplorer(
    String fen, {
    String variant = 'standard',
    String speeds = 'blitz,rapid,classical',
    String ratings = '2000,2200,2500',
    bool useMasters = false,
  }) async {
    final totalSw = Stopwatch()..start();
    final fenShort = fen.contains(' ')
        ? fen.substring(0, fen.indexOf(' '))
        : fen;

    final url = _explorerUrl(
      fen,
      variant: variant,
      speeds: speeds,
      ratings: ratings,
      useMasters: useMasters,
    );

    _profile('Explorer start fen=$fenShort');
    final getSw = Stopwatch()..start();
    final response = await get(url);
    final getMs = getSw.elapsedMilliseconds;

    if (response == null) {
      // Retries exhausted (network, or a 429 that never cleared) — whatever
      // this is, it is not an auth problem, so don't leave a stale 401 flag
      // pointing the user at a login that will not help.
      _explorerAuthRequired = false;
      _profile(
        'Explorer null response fen=$fenShort '
        'total=${totalSw.elapsedMilliseconds}ms get=${getMs}ms',
      );
      return null;
    }
    if (response.statusCode != 200) {
      // 401/403 is "no Lichess account", not "no network" — the two need
      // very different things from the user, so record which one it was.
      _explorerAuthRequired =
          response.statusCode == 401 || response.statusCode == 403;
      if (kDebugMode) {
        debugPrint(
          '[LichessAPI] Explorer HTTP ${response.statusCode} for $fenShort…',
        );
      }
      _profile(
        'Explorer HTTP ${response.statusCode} fen=$fenShort '
        'total=${totalSw.elapsedMilliseconds}ms get=${getMs}ms',
      );
      return null;
    }

    _explorerAuthRequired = false;

    final decodeSw = Stopwatch()..start();
    final data = json.decode(response.body) as Map<String, dynamic>;
    final decodeMs = decodeSw.elapsedMilliseconds;
    final parseSw = Stopwatch()..start();
    final parsed = ExplorerResponse.fromJson(
      data,
      fen: fen,
      gameSource: useMasters
          ? ExplorerGameSource.masters
          : ExplorerGameSource.lichess,
    );
    final parseMs = parseSw.elapsedMilliseconds;

    _profile(
      'Explorer done fen=$fenShort status=200 get=${getMs}ms '
      'decode=${decodeMs}ms parse=${parseMs}ms '
      'total=${totalSw.elapsedMilliseconds}ms '
      'moves=${parsed.moves.length} games=${parsed.totalGames}',
    );
    return parsed;
  }

  /// The Explorer endpoint for [fen].  The games lists are what makes the
  /// position openable, lila-style: masters lists up to 15 top games; the
  /// player database caps both of its lists at 4.
  static Uri _explorerUrl(
    String fen, {
    required String variant,
    required String speeds,
    required String ratings,
    required bool useMasters,
  }) {
    final encodedFen = Uri.encodeComponent(fen);
    if (useMasters) {
      return Uri.parse('$_explorerHost/masters?topGames=15&fen=$encodedFen');
    }
    return Uri.parse(
      '$_explorerHost/lichess?'
      'variant=$variant&'
      'speeds=$speeds&'
      'ratings=$ratings&'
      'topGames=4&'
      'recentGames=4&'
      'fen=$encodedFen',
    );
  }

  /// The PGN of one game the explorer listed, or null when it cannot be
  /// fetched.
  ///
  /// Masters games come from the explorer's own PGN endpoint; player
  /// database games from the site's export, asked for as PGN without the
  /// clock and eval comments the viewer would only strip.
  Future<String?> fetchGamePgn(String id, {required bool masters}) async {
    final safeId = Uri.encodeComponent(id);
    final url = masters
        ? Uri.parse('$_explorerHost/masters/pgn/$safeId')
        : Uri.parse(
            '$_siteHost/game/export/$safeId?evals=0&clocks=0&literate=0',
          );
    final response = await get(
      url,
      extraHeaders: const {'Accept': 'application/x-chess-pgn'},
    );
    if (response == null || response.statusCode != 200) return null;
    final body = response.body.trim();
    return body.isEmpty ? null : body;
  }

  /// Close the underlying HTTP client.
  ///
  /// Only needed for isolate instances.  The main-thread singleton should
  /// not be closed.
  void close() {
    if (_closed) return;
    _closed = true;
    _closing.complete();
    _httpClient.close();
  }
}
