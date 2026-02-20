/// Centralised HTTP client for all Lichess / Lichess Explorer API calls.
///
/// Handles:
///   • Persistent TCP connections (keep-alive) to avoid per-request TLS overhead
///   • Polite 300 ms minimum gap between requests
///   • 429 detection with exponential backoff (60 s, 120 s, 240 s …)
///   • Automatic auth-header injection
///   • Configurable retry on transient errors
///
/// Main-thread code uses the singleton: `LichessApiClient()`.
/// Isolate code creates a disposable instance via
/// `LichessApiClient.withToken(token)` and calls [close] when finished.
library;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'lichess_auth_service.dart';

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

  static const Duration politenessDelay = Duration(milliseconds: 300);
  static const int defaultMaxRetries = 3;
  static const int _baseBackoffSeconds = 60;

  // ── State ───────────────────────────────────────────────────────────

  final http.Client _httpClient;
  final String? _authToken;
  final bool _useAuthService;

  DateTime _earliestNextRequest = DateTime(0);
  DateTime _lastRequestTime = DateTime(0);

  /// Whether the client is currently in a 429-backoff window.
  bool get isBackingOff => DateTime.now().isBefore(_earliestNextRequest);

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

  Future<void> _waitForSlot() async {
    // Honour any active 429 backoff window.
    final now = DateTime.now();
    if (now.isBefore(_earliestNextRequest)) {
      final wait = _earliestNextRequest.difference(now);
      if (kDebugMode) {
        print('[LichessAPI] Backoff active — waiting ${wait.inSeconds}s');
      }
      await Future.delayed(wait);
    }

    // Polite inter-request delay.
    final gap = DateTime.now().difference(_lastRequestTime);
    if (gap < politenessDelay) {
      await Future.delayed(politenessDelay - gap);
    }
    _lastRequestTime = DateTime.now();
  }

  void _handle429(int attempt, int maxRetries, http.Response response) {
    final backoff = _baseBackoffSeconds * (1 << attempt);
    _earliestNextRequest = DateTime.now().add(Duration(seconds: backoff));
    if (kDebugMode) {
      print('[LichessAPI] 429 — backing off ${backoff}s  '
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
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      await _waitForSlot();

      try {
        final headers = await _resolveHeaders(extraHeaders);
        final response = await _httpClient.get(url, headers: headers);

        if (response.statusCode == 429) {
          _handle429(attempt, maxRetries, response);
          if (attempt < maxRetries) continue;
          return null;
        }

        return response;
      } catch (e) {
        if (kDebugMode) {
          print('[LichessAPI] GET error (attempt ${attempt + 1}): $e');
        }
        if (attempt < maxRetries) {
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
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
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      await _waitForSlot();

      try {
        final headers = await _resolveHeaders(extraHeaders);
        final response =
            await _httpClient.post(url, headers: headers, body: body);

        if (response.statusCode == 429) {
          _handle429(attempt, maxRetries, response);
          if (attempt < maxRetries) continue;
          return null;
        }

        return response;
      } catch (e) {
        if (kDebugMode) {
          print('[LichessAPI] POST error (attempt ${attempt + 1}): $e');
        }
        if (attempt < maxRetries) {
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        return null;
      }
    }
    return null;
  }

  /// Close the underlying HTTP client.
  ///
  /// Only needed for isolate instances.  The main-thread singleton should
  /// not be closed.
  void close() => _httpClient.close();
}
