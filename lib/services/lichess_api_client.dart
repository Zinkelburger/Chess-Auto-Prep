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
/// Main-thread code uses the singleton: `LichessApiClient()`.
/// Isolate code creates a disposable instance via
/// `LichessApiClient.withToken(token)` and calls [close] when finished.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/explorer_response.dart';
import 'lichess_auth_service.dart';

class _SlotWaitInfo {
  final int backoffMs;
  final int politenessMs;

  const _SlotWaitInfo({
    required this.backoffMs,
    required this.politenessMs,
  });
}

class LichessApiClient {
  // ── Singleton (main thread) ─────────────────────────────────────────

  static final LichessApiClient _instance = LichessApiClient._internal();
  factory LichessApiClient() => _instance;

  LichessApiClient._internal()
      : _httpClient = http.Client(),
        _authToken = null,
        _useAuthService = true;

  /// Create a standalone instance for use inside a Dart [Isolate].
  ///
  /// Owns its own [http.Client] and rate-limit state.  Call [close] when
  /// done to release the TCP connection pool.
  LichessApiClient.withToken(String? token)
      : _httpClient = http.Client(),
        _authToken = token,
        _useAuthService = false;

  // ── Configuration ───────────────────────────────────────────────────

  static const Duration politenessDelay = Duration(milliseconds: 100);
  static const int defaultMaxRetries = 3;
  static const int _baseBackoffSeconds = 60;

  // ── State ───────────────────────────────────────────────────────────

  final http.Client _httpClient;
  final String? _authToken;
  final bool _useAuthService;

  DateTime _earliestNextRequest = DateTime(0);
  DateTime _lastRequestTime = DateTime(0);
  bool _profilingEnabled = false;
  void Function(String message)? _profilingLogger;

  /// Whether the client is currently in a 429-backoff window.
  bool get isBackingOff => DateTime.now().isBefore(_earliestNextRequest);

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
    if (_profilingLogger != null) {
      _profilingLogger!(line);
    } else if (kDebugMode) {
      debugPrint(line);
    }
  }

  // ── Headers ─────────────────────────────────────────────────────────

  Future<Map<String, String>> _resolveHeaders([
    Map<String, String>? extra,
  ]) async {
    if (_useAuthService) {
      return LichessAuthService().getHeaders(extra);
    }
    final headers = <String, String>{};
    if (extra != null) headers.addAll(extra);
    if (_authToken != null) {
      headers['Authorization'] = 'Bearer $_authToken';
    }
    return headers;
  }

  // ── Rate-limit gate ─────────────────────────────────────────────────

  Future<_SlotWaitInfo> _waitForSlot() async {
    int backoffMs = 0;
    int politenessMs = 0;

    // Honour any active 429 backoff window.
    final now = DateTime.now();
    if (now.isBefore(_earliestNextRequest)) {
      final wait = _earliestNextRequest.difference(now);
      backoffMs = wait.inMilliseconds;
      if (kDebugMode) {
        debugPrint('[LichessAPI] Backoff active — waiting ${wait.inSeconds}s');
      }
      await Future.delayed(wait);
    }

    // Polite inter-request delay.
    final gap = DateTime.now().difference(_lastRequestTime);
    if (gap < politenessDelay) {
      final wait = politenessDelay - gap;
      politenessMs = wait.inMilliseconds;
      await Future.delayed(wait);
    }
    _lastRequestTime = DateTime.now();
    return _SlotWaitInfo(backoffMs: backoffMs, politenessMs: politenessMs);
  }

  void _handle429(int attempt, int maxRetries, http.Response response) {
    final backoff = _baseBackoffSeconds * (1 << attempt);
    _earliestNextRequest = DateTime.now().add(Duration(seconds: backoff));
    if (kDebugMode) {
      debugPrint('[LichessAPI] 429 — backing off ${backoff}s  '
          '(attempt ${attempt + 1}/$maxRetries)  '
          'Retry-After: ${response.headers['retry-after'] ?? 'none'}');
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
  }) async {
    final opSw = Stopwatch()..start();
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      final attemptSw = Stopwatch()..start();
      final waitInfo = await _waitForSlot();
      final afterWaitMs = attemptSw.elapsedMilliseconds;

      try {
        final headerSw = Stopwatch()..start();
        final headers = await _resolveHeaders(extraHeaders);
        final headerMs = headerSw.elapsedMilliseconds;

        final netSw = Stopwatch()..start();
        final response = await _httpClient.get(url, headers: headers);
        final netMs = netSw.elapsedMilliseconds;
        _profile('GET attempt=${attempt + 1}/${maxRetries + 1} '
            'status=${response.statusCode} '
            'wait=${afterWaitMs}ms(backoff=${waitInfo.backoffMs}ms,'
            'polite=${waitInfo.politenessMs}ms) '
            'headers=${headerMs}ms net=${netMs}ms '
            'attemptTotal=${attemptSw.elapsedMilliseconds}ms');

        if (response.statusCode == 429) {
          _handle429(attempt, maxRetries, response);
          if (attempt < maxRetries) continue;
          _profile('GET exhausted after 429 '
              'total=${opSw.elapsedMilliseconds}ms');
          return null;
        }

        _profile('GET done total=${opSw.elapsedMilliseconds}ms');
        return response;
      } catch (e) {
        _profile('GET error attempt=${attempt + 1}/${maxRetries + 1} '
            'elapsed=${attemptSw.elapsedMilliseconds}ms err=$e');
        if (kDebugMode) {
          debugPrint('[LichessAPI] GET error (attempt ${attempt + 1}): $e');
        }
        if (attempt < maxRetries) {
          await Future.delayed(const Duration(seconds: 2));
          _profile('GET retry sleep=2000ms');
          continue;
        }
        _profile('GET failed total=${opSw.elapsedMilliseconds}ms');
        return null;
      }
    }
    return null;
  }

  /// HTTP POST with automatic rate-limiting and retries.
  ///
  /// Returns the [http.Response] on success (any non-429 status code).
  /// Returns `null` only when all retry attempts are exhausted.
  Future<http.Response?> post(
    Uri url, {
    Object? body,
    Map<String, String>? extraHeaders,
    int maxRetries = defaultMaxRetries,
  }) async {
    final opSw = Stopwatch()..start();
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      final attemptSw = Stopwatch()..start();
      final waitInfo = await _waitForSlot();
      final afterWaitMs = attemptSw.elapsedMilliseconds;

      try {
        final headerSw = Stopwatch()..start();
        final headers = await _resolveHeaders(extraHeaders);
        final headerMs = headerSw.elapsedMilliseconds;
        final netSw = Stopwatch()..start();
        final response =
            await _httpClient.post(url, headers: headers, body: body);
        final netMs = netSw.elapsedMilliseconds;
        _profile('POST attempt=${attempt + 1}/${maxRetries + 1} '
            'status=${response.statusCode} '
            'wait=${afterWaitMs}ms(backoff=${waitInfo.backoffMs}ms,'
            'polite=${waitInfo.politenessMs}ms) '
            'headers=${headerMs}ms net=${netMs}ms '
            'attemptTotal=${attemptSw.elapsedMilliseconds}ms');

        if (response.statusCode == 429) {
          _handle429(attempt, maxRetries, response);
          if (attempt < maxRetries) continue;
          _profile('POST exhausted after 429 '
              'total=${opSw.elapsedMilliseconds}ms');
          return null;
        }

        _profile('POST done total=${opSw.elapsedMilliseconds}ms');
        return response;
      } catch (e) {
        _profile('POST error attempt=${attempt + 1}/${maxRetries + 1} '
            'elapsed=${attemptSw.elapsedMilliseconds}ms err=$e');
        if (kDebugMode) {
          debugPrint('[LichessAPI] POST error (attempt ${attempt + 1}): $e');
        }
        if (attempt < maxRetries) {
          await Future.delayed(const Duration(seconds: 2));
          _profile('POST retry sleep=2000ms');
          continue;
        }
        _profile('POST failed total=${opSw.elapsedMilliseconds}ms');
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
  Future<ExplorerResponse?> fetchExplorer(
    String fen, {
    String variant = 'standard',
    String speeds = 'blitz,rapid,classical',
    String ratings = '2000,2200,2500',
  }) async {
    final totalSw = Stopwatch()..start();
    final fenShort =
        fen.contains(' ') ? fen.substring(0, fen.indexOf(' ')) : fen;

    final encodedFen = Uri.encodeComponent(fen);
    final url = Uri.parse('https://explorer.lichess.ovh/lichess?'
        'variant=$variant&'
        'speeds=$speeds&'
        'ratings=$ratings&'
        'fen=$encodedFen');

    _profile('Explorer start fen=$fenShort');
    final getSw = Stopwatch()..start();
    final response = await get(url);
    final getMs = getSw.elapsedMilliseconds;

    if (response == null) {
      _profile('Explorer null response fen=$fenShort '
          'total=${totalSw.elapsedMilliseconds}ms get=${getMs}ms');
      return null;
    }
    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint(
            '[LichessAPI] Explorer HTTP ${response.statusCode} for $fenShort…');
      }
      _profile('Explorer HTTP ${response.statusCode} fen=$fenShort '
          'total=${totalSw.elapsedMilliseconds}ms get=${getMs}ms');
      return null;
    }

    final decodeSw = Stopwatch()..start();
    final data = json.decode(response.body) as Map<String, dynamic>;
    final decodeMs = decodeSw.elapsedMilliseconds;
    final parseSw = Stopwatch()..start();
    final parsed = ExplorerResponse.fromJson(data, fen: fen);
    final parseMs = parseSw.elapsedMilliseconds;

    _profile('Explorer done fen=$fenShort status=200 get=${getMs}ms '
        'decode=${decodeMs}ms parse=${parseMs}ms '
        'total=${totalSw.elapsedMilliseconds}ms '
        'moves=${parsed.moves.length} games=${parsed.totalGames}');
    return parsed;
  }

  /// Close the underlying HTTP client.
  ///
  /// Only needed for isolate instances.  The main-thread singleton should
  /// not be closed.
  void close() => _httpClient.close();
}
