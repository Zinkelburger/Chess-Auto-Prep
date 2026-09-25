import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../diagnostics/log.dart';
import 'lichess_http.dart';

/// Logging into Lichess: the OAuth PKCE flow the old app used, and a typed
/// personal access token as the way in when a browser is not to hand.
///
/// Lichess registers no clients: any id and any loopback redirect are
/// accepted, the token lasts about a year and there is no refresh token.
/// The flow is: bind a small server on this computer, send the browser to
/// `lichess.org/oauth` with a code challenge, wait for the browser to be
/// sent back to the server with a code, swap the code for the token, ask
/// `/api/account` whose token it is.
abstract interface class LichessLogin {
  /// Runs the browser flow. [waiting] is told the page to open once the
  /// server is up and whether the browser took it, so the user can be
  /// shown the link when it did not. Returns when the flow ends either way.
  Future<LoginOutcome> logIn({
    required void Function(Uri page, {required bool opened}) waiting,
  });

  /// Ends a browser flow that is waiting; [logIn] then returns
  /// [LoginCancelled].
  Future<void> cancel();

  /// Checks a personal access token with Lichess and names its account.
  Future<LoginOutcome> withToken(String token);

  /// Asks Lichess to forget [token]. Best effort: a token Lichess no longer
  /// knows is as gone as one it revoked.
  Future<void> revoke(String token);
}

sealed class LoginOutcome {
  const LoginOutcome();
}

final class LoggedIn extends LoginOutcome {
  const LoggedIn(this.account);

  final LichessGrant account;
}

/// The account a login reached and the token that reaches it, as Lichess
/// answered. Keeping it is the caller's: this client never stores it.
final class LichessGrant {
  const LichessGrant({
    required this.token,
    required this.username,
    this.until,
    this.personal = false,
  });

  /// The bearer token. Never logged, never shown in full.
  final String token;

  /// The account's name as Lichess spells it; null when Lichess did not
  /// say.
  final String? username;

  /// When an OAuth token stops working; null for a personal access token,
  /// which lasts until revoked.
  final DateTime? until;

  /// Typed in as a personal access token rather than obtained by logging in.
  final bool personal;
}

/// The user pressed Cancel in the app.
final class LoginCancelled extends LoginOutcome {
  const LoginCancelled();
}

/// Why the login did not happen. The sentence is what the row shows.
enum LoginProblem {
  denied('Lichess said the login was declined.'),
  timedOut('No answer from the browser in five minutes.'),
  portBusy('Could not open a port for the browser to come back to.'),
  unreachable('Could not reach lichess.org — it needs a connection.'),
  rejected('Lichess turned the login away.'),
  tokenRejected(
    'Lichess rejected that token. Check it was copied fully and has not '
    'been revoked.',
  ),
  http('Lichess could not answer.');

  const LoginProblem(this.sentence);

  final String sentence;
}

final class LoginFailed extends LoginOutcome {
  const LoginFailed(this.problem);

  final LoginProblem problem;
}

/// The old app's client id; any string does for a public PKCE client.
const lichessClientId = 'chess-auto-prep';

/// The port the old app listened on; another is taken when it is busy.
const lichessCallbackPort = 8919;

/// What the token may do: the account's name, and private studies.
/// Game exports and the explorer need no scope; the token only lifts the
/// rate limit.
const lichessScopes = 'preference:read study:read';

const _authorizeUrl = 'https://lichess.org/oauth';
const _tokenUrl = 'https://lichess.org/api/token';
const _accountUrl = 'https://lichess.org/api/account';

/// How long a token lives when Lichess does not say.
const _defaultLife = Duration(days: 365);

/// How long one request to Lichess may take before it counts as lost.
const _requestTimeout = Duration(seconds: 20);

final class LichessLoginApi implements LichessLogin {
  LichessLoginApi(
    this._client, {
    required Future<bool> Function(Uri) openBrowser,
    this.wait = const Duration(minutes: 5),
    Random? random,
  }) : _openBrowser = openBrowser,
       _random = random ?? Random.secure();

  final http.Client _client;

  /// Opens a page in the desktop's browser and says whether it went.
  final Future<bool> Function(Uri) _openBrowser;

  /// How long the browser may take before the flow gives up.
  final Duration wait;

  final Random _random;

  _Flow? _flow;

  @override
  Future<LoginOutcome> logIn({
    required void Function(Uri page, {required bool opened}) waiting,
  }) async {
    await cancel();
    final HttpServer server;
    try {
      server = await _bind();
    } on SocketException catch (error) {
      log.w('log into Lichess', error);
      return const LoginFailed(LoginProblem.portBusy);
    }
    final verifier = _randomToken(64);
    final state = _randomToken(24);
    final flow = _Flow(server, verifier: verifier, state: state);
    _flow = flow;
    final redirect = 'http://127.0.0.1:${server.port}/callback';
    server.listen((request) => unawaited(_answer(request, flow)));

    // Built by hand: `Uri` would encode the colons of the scopes, and the
    // desktop's URL handler has been seen re-encoding the `%`.
    final page = Uri.parse(
      '$_authorizeUrl?response_type=code'
      '&client_id=${Uri.encodeQueryComponent(lichessClientId)}'
      '&redirect_uri=${Uri.encodeQueryComponent(redirect)}'
      '&code_challenge_method=S256'
      '&code_challenge=${_challenge(verifier)}'
      '&scope=${lichessScopes.replaceAll(' ', '+')}'
      '&state=$state',
    );
    var opened = false;
    try {
      opened = await _openBrowser(page);
    } on Object catch (error) {
      log.w('open the browser for the Lichess login', error);
    }
    if (!opened) log.w('open the browser for the Lichess login', 'declined');
    waiting(page, opened: opened);

    try {
      final code = await flow.code.future.timeout(wait);
      return switch (code) {
        null => const LoginCancelled(),
        _Denied() => const LoginFailed(LoginProblem.denied),
        final String code => await _exchange(code, verifier, redirect),
        _ => const LoginFailed(LoginProblem.http),
      };
    } on TimeoutException {
      log.w('log into Lichess', 'no callback in ${wait.inMinutes} minutes');
      return const LoginFailed(LoginProblem.timedOut);
    } finally {
      await _close(flow);
    }
  }

  /// Bind the same literal loopback address the redirect names. A dual-stack
  /// IPv6 bind behaves differently on macOS; letting localhost choose a
  /// family can send the browser to a different process on the other one.
  /// Try the old app's port first, then any free port on this address.
  Future<HttpServer> _bind() async {
    for (final port in [lichessCallbackPort, 0]) {
      try {
        return await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      } on SocketException {
        if (port != lichessCallbackPort) rethrow;
      }
    }
    throw const SocketException('no loopback port');
  }

  /// The browser has come back. It is answered in full before the flow
  /// moves on, because moving on closes the server under it.
  Future<void> _answer(HttpRequest request, _Flow flow) async {
    final query = request.uri.queryParameters;
    final isCallback =
        request.uri.path == '/callback' && query['state'] == flow.state;
    final code = query['code'];
    final ok = isCallback && code != null && query['error'] == null;
    try {
      request.response
        ..statusCode = isCallback ? 200 : 404
        ..headers.contentType = ContentType.html
        ..write(_page(ok));
      await request.response.close();
    } on Object catch (error) {
      log.w('answer the browser after the Lichess login', error);
    }
    if (!isCallback || flow.code.isCompleted) return;
    flow.code.complete(ok ? code : const _Denied());
  }

  Future<LoginOutcome> _exchange(
    String code,
    String verifier,
    String redirect,
  ) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse(_tokenUrl),
            headers: lichessHeaders(),
            body: {
              'grant_type': 'authorization_code',
              'code': code,
              'client_id': lichessClientId,
              'code_verifier': verifier,
              'redirect_uri': redirect,
            },
          )
          .timeout(_requestTimeout);
    } on Object catch (error) {
      log.w('swap the Lichess code for a token', error);
      return const LoginFailed(LoginProblem.unreachable);
    }
    if (response.statusCode != 200) {
      log.w('swap the Lichess code for a token', 'HTTP ${response.statusCode}');
      return LoginFailed(
        response.statusCode == 400 || response.statusCode == 401
            ? LoginProblem.rejected
            : LoginProblem.http,
      );
    }
    final String token;
    final Duration life;
    try {
      final body = json.decode(response.body) as Map<String, Object?>;
      token = body['access_token'] as String;
      life = switch (body['expires_in']) {
        final int seconds => Duration(seconds: seconds),
        _ => _defaultLife,
      };
    } on Object catch (error) {
      log.w('read the Lichess token answer', error);
      return const LoginFailed(LoginProblem.http);
    }
    final named = await _account(token);
    return switch (named) {
      LoginFailed() => named,
      LoggedIn(:final account) => LoggedIn(
        LichessGrant(
          token: token,
          username: account.username,
          until: DateTime.now().add(life),
        ),
      ),
      LoginCancelled() => named,
    };
  }

  @override
  Future<LoginOutcome> withToken(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) return const LoginFailed(LoginProblem.tokenRejected);
    final named = await _account(trimmed);
    return switch (named) {
      LoggedIn(:final account) => LoggedIn(
        LichessGrant(
          token: trimmed,
          username: account.username,
          personal: true,
        ),
      ),
      LoginFailed(problem: LoginProblem.rejected) => const LoginFailed(
        LoginProblem.tokenRejected,
      ),
      _ => named,
    };
  }

  /// Whose token this is. The account it answers carries the name and the
  /// token, nothing else; callers fill in the rest.
  Future<LoginOutcome> _account(String token) async {
    final http.Response response;
    try {
      response = await _client
          .get(Uri.parse(_accountUrl), headers: lichessHeaders(token: token))
          .timeout(_requestTimeout);
    } on Object catch (error) {
      log.w('ask Lichess whose token this is', error);
      return const LoginFailed(LoginProblem.unreachable);
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      log.w('ask Lichess whose token this is', 'HTTP ${response.statusCode}');
      return const LoginFailed(LoginProblem.rejected);
    }
    if (response.statusCode != 200) {
      log.w('ask Lichess whose token this is', 'HTTP ${response.statusCode}');
      return const LoginFailed(LoginProblem.http);
    }
    String? name;
    try {
      name =
          (json.decode(response.body) as Map<String, Object?>)['username']
              as String?;
    } on Object catch (error) {
      log.w('read the Lichess account answer', error);
    }
    return LoggedIn(LichessGrant(token: token, username: name));
  }

  @override
  Future<void> revoke(String token) async {
    try {
      final request = http.Request('DELETE', Uri.parse(_tokenUrl))
        ..headers.addAll(lichessHeaders(token: token));
      await _client.send(request).timeout(_requestTimeout);
    } on Object catch (error) {
      log.w('revoke the Lichess token', error);
    }
  }

  @override
  Future<void> cancel() async {
    final flow = _flow;
    if (flow == null) return;
    if (!flow.code.isCompleted) flow.code.complete(null);
    await _close(flow);
  }

  Future<void> _close(_Flow flow) async {
    if (_flow == flow) _flow = null;
    await flow.server.close(force: true);
  }

  String _randomToken(int bytes) => base64Url
      .encode(List<int>.generate(bytes, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  static String _challenge(String verifier) => base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');
}

/// A running browser flow: the server the browser comes back to, what it
/// must bring, and the code it brought (null when cancelled in the app).
final class _Flow {
  _Flow(this.server, {required this.verifier, required this.state});

  final HttpServer server;
  final String verifier;
  final String state;
  final code = Completer<Object?>();
}

/// The browser came back saying no.
final class _Denied {
  const _Denied();
}

/// What the browser shows once it has been sent back here.
String _page(bool ok) =>
    '<!DOCTYPE html><html><head><meta charset="utf-8">'
    '<title>Chess Auto Prep</title></head>'
    '<body style="font-family:sans-serif;background:#1b1b1d;color:#e6e6e8;'
    'text-align:center;padding-top:80px">'
    '<p style="font-size:20px">${ok ? 'Logged in.' : 'Not logged in.'}</p>'
    '<p>${ok ? 'You can close this tab and go back to Chess Auto Prep.' : 'Go back to Chess Auto Prep and try again.'}</p>'
    '</body></html>';
