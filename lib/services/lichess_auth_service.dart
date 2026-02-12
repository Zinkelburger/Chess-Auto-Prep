/// Lichess OAuth 2.0 PKCE authentication service.
///
/// Handles the full authorization flow:
///   1. PKCE code generation & local callback server
///   2. Token exchange & refresh
///   3. Persistent token storage via SharedPreferences
///   4. Personal Access Token (PAT) support as a fallback
///
/// Usage:
///   final auth = LichessAuthService();
///   await auth.loadTokens(); // on startup
///   final headers = await auth.getHeaders({'Accept': '...'});
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class LichessAuthService extends ChangeNotifier {
  // ── Configuration ──────────────────────────────────────────────────

  /// Client ID — Lichess allows arbitrary IDs for PKCE public clients.
  static const String clientId = 'chess-auto-prep';

  /// Port for the local HTTP callback server.
  static const int _callbackPort = 8919;

  static const String _redirectUri =
      'http://localhost:$_callbackPort/callback';

  /// OAuth scopes requested.
  ///
  /// We only need `preference:read` (for account info like username).
  /// Game exports and the opening explorer work without scopes — auth
  /// just gives us higher rate limits.
  /// Note: there is no `game:read` scope in Lichess OAuth.
  static const String _scopes = 'preference:read';

  // ── SharedPreferences keys ─────────────────────────────────────────

  static const String _keyAccessToken = 'lichess_access_token';
  static const String _keyRefreshToken = 'lichess_refresh_token';
  static const String _keyTokenExpiry = 'lichess_token_expiry';
  static const String _keyUsername = 'lichess_auth_username';
  static const String _keyIsPat = 'lichess_is_pat';

  // ── Singleton ──────────────────────────────────────────────────────

  static final LichessAuthService _instance = LichessAuthService._internal();
  factory LichessAuthService() => _instance;
  LichessAuthService._internal();

  // ── State ──────────────────────────────────────────────────────────

  String? _accessToken;
  String? _refreshToken;
  DateTime? _tokenExpiry;
  String? _username;
  bool _isPat = false;

  // PKCE flow state
  String? _codeVerifier;
  HttpServer? _callbackServer;
  Completer<String?>? _callbackCompleter;

  // ── Getters ────────────────────────────────────────────────────────

  bool get isLoggedIn => _accessToken != null;
  String? get username => _username;
  bool get isPat => _isPat;
  DateTime? get tokenExpiry => _tokenExpiry;

  // ── Token persistence ──────────────────────────────────────────────

  /// Load stored tokens from disk. Call once during app startup.
  Future<void> loadTokens() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString(_keyAccessToken);
    _refreshToken = prefs.getString(_keyRefreshToken);
    _username = prefs.getString(_keyUsername);
    _isPat = prefs.getBool(_keyIsPat) ?? false;

    final expiryMs = prefs.getInt(_keyTokenExpiry);
    if (expiryMs != null) {
      _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(expiryMs);
    }

    // Lichess OAuth tokens are long-lived (~1 year) and refresh tokens
    // are NOT supported.  If the token has expired, clear it and ask
    // the user to log in again.
    if (_accessToken != null && !_isPat && _isTokenExpired) {
      if (kDebugMode) {
        print('[LichessAuth] Stored OAuth token expired — clearing');
      }
      await _clearTokens();
    }

    notifyListeners();
  }

  bool get _isTokenExpired =>
      _tokenExpiry != null && DateTime.now().isAfter(_tokenExpiry!);

  Future<void> _saveTokens() async {
    final prefs = await SharedPreferences.getInstance();

    Future<void> setOrRemove(String key, String? value) =>
        value != null ? prefs.setString(key, value) : prefs.remove(key);

    await setOrRemove(_keyAccessToken, _accessToken);
    await setOrRemove(_keyRefreshToken, _refreshToken);
    await setOrRemove(_keyUsername, _username);
    await prefs.setBool(_keyIsPat, _isPat);

    if (_tokenExpiry != null) {
      await prefs.setInt(
          _keyTokenExpiry, _tokenExpiry!.millisecondsSinceEpoch);
    } else {
      await prefs.remove(_keyTokenExpiry);
    }
  }

  /// Clear tokens from memory and disk without revoking remotely.
  Future<void> _clearTokens() async {
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiry = null;
    _username = null;
    _isPat = false;
    await _saveTokens();
    notifyListeners();
  }

  // ── OAuth PKCE flow ────────────────────────────────────────────────

  /// Start the PKCE authorization flow.
  ///
  /// Returns the authorization URL that the user should visit in a
  /// browser. Also starts a local HTTP server on [_callbackPort] to
  /// receive the redirect.
  Future<String> startOAuthFlow() async {
    // Generate PKCE code verifier (cryptographically random, 43-128 chars)
    final random = Random.secure();
    final bytes = List<int>.generate(64, (_) => random.nextInt(256));
    _codeVerifier = base64Url.encode(bytes).replaceAll('=', '');

    // Derive code challenge: SHA-256, base64url, no padding
    final digest = sha256.convert(ascii.encode(_codeVerifier!));
    final codeChallenge = base64Url.encode(digest.bytes).replaceAll('=', '');

    // Start local callback server to receive the OAuth redirect
    await _stopCallbackServer();
    try {
      _callbackServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        _callbackPort,
      );
    } catch (e) {
      if (kDebugMode) {
        print('[LichessAuth] Failed to bind callback server on '
            'port $_callbackPort: $e');
      }
      rethrow;
    }
    _callbackCompleter = Completer<String?>();

    if (kDebugMode) {
      print('[LichessAuth] OAuth callback server listening on '
          'http://localhost:$_callbackPort/callback');
    }

    _callbackServer!.listen((request) {
      if (kDebugMode) {
        print('[LichessAuth] Received ${request.method} ${request.uri}');
      }
      if (request.uri.path == '/callback') {
        final code = request.uri.queryParameters['code'];
        final error = request.uri.queryParameters['error'];

        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(_callbackHtml(code != null && error == null));
        request.response.close();

        if (kDebugMode) {
          print('[LichessAuth] Callback received — '
              '${code != null ? 'auth code OK' : 'error: $error'}');
        }

        if (!_callbackCompleter!.isCompleted) {
          _callbackCompleter!.complete(error == null ? code : null);
        }
      }
    });

    // Build authorization URL.
    //
    // We construct the query string manually instead of using
    // `Uri(queryParameters: ...)` because Dart's URI encoder
    // percent-encodes colons in query values (`game:read` → `game%3Aread`).
    // While technically valid, some browsers or URL handlers re-encode
    // the `%` when opening via xdg-open, producing `game%253Aread` and
    // causing Lichess to reject the scope.  Colons are legal in query
    // strings per RFC 3986, so we leave them unencoded.
    final query = 'response_type=code'
        '&client_id=${Uri.encodeQueryComponent(clientId)}'
        '&redirect_uri=${Uri.encodeQueryComponent(_redirectUri)}'
        '&code_challenge_method=S256'
        '&code_challenge=$codeChallenge'
        '&scope=${_scopes.replaceAll(' ', '+')}';

    final url = 'https://lichess.org/oauth?$query';
    if (kDebugMode) print('[LichessAuth] Authorization URL: $url');
    return url;
  }

  /// Wait for the OAuth callback. Returns `true` if tokens were obtained.
  Future<bool> waitForCallback({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (_callbackCompleter == null) return false;

    if (kDebugMode) {
      print('[LichessAuth] Waiting for OAuth callback '
          '(timeout ${timeout.inSeconds}s)...');
    }

    try {
      final code = await _callbackCompleter!.future.timeout(timeout);
      if (code == null) {
        if (kDebugMode) print('[LichessAuth] Callback returned null (denied)');
        return false;
      }
      final ok = await _exchangeCode(code);
      if (kDebugMode) {
        print('[LichessAuth] Token exchange '
            '${ok ? 'succeeded — logged in as $_username' : 'FAILED'}');
      }
      return ok;
    } on TimeoutException {
      if (kDebugMode) print('[LichessAuth] OAuth callback timed out');
      return false;
    } finally {
      await _stopCallbackServer();
    }
  }

  /// Exchange the authorization code for an access token.
  ///
  /// Lichess PKCE tokens are long-lived (~1 year) and there is no
  /// refresh token.
  Future<bool> _exchangeCode(String code) async {
    try {
      final response = await http.post(
        Uri.parse('https://lichess.org/api/token'),
        body: {
          'grant_type': 'authorization_code',
          'code': code,
          'client_id': clientId,
          'code_verifier': _codeVerifier!,
          'redirect_uri': _redirectUri,
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        _accessToken = data['access_token'] as String?;
        // Lichess does not issue refresh tokens for PKCE flows.
        _refreshToken = null;
        _isPat = false;

        // Lichess tokens last ~1 year; use `expires_in` if provided,
        // otherwise default to 365 days.
        final expiresIn = data['expires_in'] as int? ?? 31536000;
        _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));

        if (kDebugMode) {
          print('[LichessAuth] Token obtained — expires in '
              '${(expiresIn / 86400).round()} days');
        }

        await _fetchUsername();
        await _saveTokens();
        notifyListeners();
        return true;
      }

      if (kDebugMode) {
        print('[LichessAuth] Token exchange failed: '
            '${response.statusCode} ${response.body}');
      }
    } catch (e) {
      if (kDebugMode) print('[LichessAuth] Token exchange error: $e');
    }
    return false;
  }

  // ── Token access ───────────────────────────────────────────────────

  /// Return a valid access token, or `null` if expired / not logged in.
  ///
  /// Lichess PKCE tokens are long-lived (~1 year) and there is no
  /// refresh mechanism.  When a token expires the user must log in
  /// again.
  Future<String?> getValidToken() async {
    if (_accessToken == null) return null;
    if (_isPat) return _accessToken; // PATs don't expire

    if (_isTokenExpired) {
      if (kDebugMode) print('[LichessAuth] Token expired — please log in again');
      await _clearTokens();
      return null;
    }

    return _accessToken;
  }

  /// Build HTTP headers with Bearer auth merged in.
  ///
  /// Pass your existing headers (e.g. `{'Accept': 'application/x-chess-pgn'}`)
  /// and the auth token will be added automatically if available.
  /// Returns the headers unchanged if not authenticated.
  Future<Map<String, String>> getHeaders([
    Map<String, String>? extra,
  ]) async {
    final headers = <String, String>{};
    if (extra != null) headers.addAll(extra);

    final token = await getValidToken();
    if (token != null) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  // ── Personal Access Token ──────────────────────────────────────────

  /// Validate and store a Personal Access Token.
  ///
  /// PATs never expire and don't need a refresh token.
  /// Returns `true` if the token is valid (verified via `/api/account`).
  Future<bool> setPersonalAccessToken(String token) async {
    try {
      final response = await http.get(
        Uri.parse('https://lichess.org/api/account'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        _accessToken = token;
        _refreshToken = null;
        _tokenExpiry = null;
        _isPat = true;
        _username = data['username'] as String?;

        await _saveTokens();
        notifyListeners();
        return true;
      }
    } catch (e) {
      if (kDebugMode) print('[LichessAuth] PAT validation failed: $e');
    }
    return false;
  }

  // ── Account info ───────────────────────────────────────────────────

  Future<void> _fetchUsername() async {
    if (_accessToken == null) return;

    try {
      final response = await http.get(
        Uri.parse('https://lichess.org/api/account'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        _username = data['username'] as String?;
      }
    } catch (e) {
      if (kDebugMode) print('[LichessAuth] Failed to fetch username: $e');
    }
  }

  // ── Logout ─────────────────────────────────────────────────────────

  /// Revoke the token with Lichess and clear all stored auth data.
  Future<void> logout() async {
    if (_accessToken != null) {
      try {
        await http.delete(
          Uri.parse('https://lichess.org/api/token'),
          headers: {'Authorization': 'Bearer $_accessToken'},
        );
      } catch (_) {
        // Best effort — token may already be invalid
      }
    }

    await _clearTokens();
  }

  // ── Cleanup ────────────────────────────────────────────────────────

  /// Cancel an in-progress OAuth flow.
  Future<void> cancelOAuthFlow() async {
    if (_callbackCompleter != null && !_callbackCompleter!.isCompleted) {
      _callbackCompleter!.complete(null);
    }
    await _stopCallbackServer();
  }

  Future<void> _stopCallbackServer() async {
    await _callbackServer?.close(force: true);
    _callbackServer = null;
  }

  // ── URL launcher (desktop) ─────────────────────────────────────────

  /// Open a URL in the default system browser.
  static Future<void> openUrl(String url) async {
    try {
      if (Platform.isLinux) {
        await Process.run('xdg-open', [url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isWindows) {
        await Process.run('start', [url], runInShell: true);
      }
    } catch (e) {
      if (kDebugMode) print('[LichessAuth] Failed to open URL: $e');
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────

  String _callbackHtml(bool success) => '''<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Chess Auto Prep</title></head>
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
             text-align: center; padding-top: 80px;
             background: #161512; color: #bababa;">
  <div style="max-width: 420px; margin: 0 auto;">
    <h1 style="font-size: 48px; margin-bottom: 12px;">
      ${success ? '&#10003;' : '&#10007;'}
    </h1>
    <h2 style="color: ${success ? '#629924' : '#bf555b'};">
      ${success ? 'Authorization Successful' : 'Authorization Failed'}
    </h2>
    <p style="color: #999;">
      ${success ? 'You can close this tab and return to Chess Auto Prep.' : 'Something went wrong. Please try again in the app.'}
    </p>
  </div>
</body>
</html>''';
}
