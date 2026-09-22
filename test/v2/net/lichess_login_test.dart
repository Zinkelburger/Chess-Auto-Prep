import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chess_auto_prep/v2/net/lichess_login.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real flow against a real loopback server: this test is the
/// browser, coming back to the page the app opened.
void main() {
  // `flutter test` answers every HttpClient with an empty 400 once a widget
  // binding is up; none is here, but be sure the loopback is reachable.
  HttpOverrides.global = null;

  /// Lichess, as the client sees it: the token exchange and the account.
  late List<http.Request> seen;
  late Map<String, Object?> tokenAnswer;
  late int tokenStatus;
  late int accountStatus;

  MockClient lichess() => MockClient((request) async {
    seen.add(request);
    if (request.url.path == '/api/token' && request.method == 'POST') {
      return http.Response(json.encode(tokenAnswer), tokenStatus);
    }
    if (request.url.path == '/api/account') {
      return http.Response(
        json.encode({'username': 'DrNykterstein'}),
        accountStatus,
      );
    }
    if (request.url.path == '/api/token' && request.method == 'DELETE') {
      return http.Response('', 204);
    }
    return http.Response('nope', 404);
  });

  setUp(() {
    seen = [];
    tokenAnswer = {'access_token': 'lip_new', 'expires_in': 5184000};
    tokenStatus = 200;
    accountStatus = 200;
  });

  /// Runs the flow with a browser that only remembers the page, and hands
  /// back the page and the outcome's future.
  (Future<LoginOutcome>, Future<Uri>) start(
    LichessLoginApi api, {
    bool opens = true,
  }) {
    final page = Completer<Uri>();
    final outcome = api.logIn(
      waiting: (uri, {required opened}) {
        expect(opened, opens);
        page.complete(uri);
      },
    );
    return (outcome, page.future);
  }

  /// The browser, sent back to the app with what Lichess put in the query.
  Future<int> comeBack(Uri page, Map<String, String> query) async {
    final params = page.queryParameters;
    final redirect = Uri.parse(params['redirect_uri']!);
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        redirect.replace(queryParameters: query),
      );
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close();
    }
  }

  LichessLoginApi api({bool opens = true, Duration? wait}) => LichessLoginApi(
    lichess(),
    openBrowser: (_) async => opens,
    wait: wait ?? const Duration(seconds: 5),
    random: Random(7),
  );

  test('the page asks Lichess with S256 and a loopback redirect', () async {
    final login = api();
    final (outcome, pageFuture) = start(login);
    final page = await pageFuture;
    expect(page.host, 'lichess.org');
    expect(page.path, '/oauth');
    final q = page.queryParameters;
    expect(q['response_type'], 'code');
    expect(q['client_id'], lichessClientId);
    expect(q['code_challenge_method'], 'S256');
    expect(q['scope'], 'preference:read study:read');
    expect(q['state'], isNotEmpty);
    final redirect = Uri.parse(q['redirect_uri']!);
    expect(redirect.host, 'localhost');
    expect(redirect.path, '/callback');
    await login.cancel();
    expect(await outcome, isA<LoginCancelled>());
  });

  test('the browser coming back with a code logs in', () async {
    final login = api();
    final (outcome, pageFuture) = start(login);
    final page = await pageFuture;
    final status = await comeBack(page, {
      'code': 'c0de',
      'state': page.queryParameters['state']!,
    });
    expect(status, 200);
    final result = await outcome;
    final account = (result as LoggedIn).account;
    expect(account.token, 'lip_new');
    expect(account.username, 'DrNykterstein');
    expect(account.personal, isFalse);
    expect(
      account.until!.difference(DateTime.now()).inDays,
      inInclusiveRange(59, 60),
    );

    final exchange = seen.firstWhere((r) => r.method == 'POST');
    final body = Uri.splitQueryString(exchange.body);
    expect(body['grant_type'], 'authorization_code');
    expect(body['code'], 'c0de');
    expect(body['redirect_uri'], page.queryParameters['redirect_uri']);
    // The verifier the client sent hashes to the challenge the page carried.
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(body['code_verifier']!)).bytes)
        .replaceAll('=', '');
    expect(page.queryParameters['code_challenge'], challenge);
    final whose = seen.firstWhere((r) => r.url.path == '/api/account');
    expect(whose.headers['Authorization'], 'Bearer lip_new');
  });

  test('a token answer with no expiry lasts a year', () async {
    tokenAnswer = {'access_token': 'lip_new'};
    final login = api();
    final (outcome, pageFuture) = start(login);
    final page = await pageFuture;
    await comeBack(page, {
      'code': 'c0de',
      'state': page.queryParameters['state']!,
    });
    final account = (await outcome as LoggedIn).account;
    expect(
      account.until!.difference(DateTime.now()).inDays,
      inInclusiveRange(364, 365),
    );
  });

  test('the browser coming back with the wrong state is a stranger', () async {
    final login = api();
    final (outcome, pageFuture) = start(login);
    final page = await pageFuture;
    expect(await comeBack(page, {'code': 'c0de', 'state': 'forged'}), 404);
    expect(seen, isEmpty, reason: 'no exchange for a forged callback');
    await login.cancel();
    expect(await outcome, isA<LoginCancelled>());
  });

  test('the browser coming back with an error is a denial', () async {
    final login = api();
    final (outcome, pageFuture) = start(login);
    final page = await pageFuture;
    await comeBack(page, {
      'error': 'access_denied',
      'state': page.queryParameters['state']!,
    });
    expect((await outcome as LoginFailed).problem, LoginProblem.denied);
  });

  test('no browser in time is a timeout, and the port is freed', () async {
    final login = api(wait: const Duration(milliseconds: 200));
    final (outcome, pageFuture) = start(login);
    final page = await pageFuture;
    expect((await outcome as LoginFailed).problem, LoginProblem.timedOut);
    final redirect = Uri.parse(page.queryParameters['redirect_uri']!);
    final again = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      redirect.port,
    );
    await again.close();
  });

  test('a browser that does not open is said so, and the flow waits', () async {
    final login = api(opens: false);
    final (outcome, pageFuture) = start(login, opens: false);
    final page = await pageFuture;
    await comeBack(page, {
      'code': 'c0de',
      'state': page.queryParameters['state']!,
    });
    expect(await outcome, isA<LoggedIn>());
  });

  test('a busy old port is passed over for another', () async {
    // Both loopbacks, as a server on the wildcard holds them.
    final busy = await HttpServer.bind(
      InternetAddress.anyIPv6,
      lichessCallbackPort,
      v6Only: false,
    );
    try {
      final login = api();
      final (outcome, pageFuture) = start(login);
      final page = await pageFuture;
      final redirect = Uri.parse(page.queryParameters['redirect_uri']!);
      expect(redirect.port, isNot(lichessCallbackPort));
      await login.cancel();
      await outcome;
    } finally {
      await busy.close();
    }
  });

  test(
    'a refused exchange is a rejection; a broken one is unreachable',
    () async {
      tokenStatus = 400;
      var login = api();
      var (outcome, pageFuture) = start(login);
      var page = await pageFuture;
      await comeBack(page, {
        'code': 'c0de',
        'state': page.queryParameters['state']!,
      });
      expect((await outcome as LoginFailed).problem, LoginProblem.rejected);

      login = LichessLoginApi(
        MockClient((_) => throw const SocketException('down')),
        openBrowser: (_) async => true,
        wait: const Duration(seconds: 5),
      );
      (outcome, pageFuture) = start(login);
      page = await pageFuture;
      await comeBack(page, {
        'code': 'c0de',
        'state': page.queryParameters['state']!,
      });
      expect((await outcome as LoginFailed).problem, LoginProblem.unreachable);
    },
  );

  test('a personal token is checked with the account and marked', () async {
    final login = api();
    final account = (await login.withToken(' lip_mine ') as LoggedIn).account;
    expect(account.token, 'lip_mine');
    expect(account.username, 'DrNykterstein');
    expect(account.personal, isTrue);
    expect(account.until, isNull);
  });

  test('a rejected or empty personal token says so', () async {
    accountStatus = 401;
    final login = api();
    expect(
      (await login.withToken('bad') as LoginFailed).problem,
      LoginProblem.tokenRejected,
    );
    expect(
      (await login.withToken('  ') as LoginFailed).problem,
      LoginProblem.tokenRejected,
    );
  });

  test('revoking sends the token to Lichess and swallows a failure', () async {
    final login = api();
    await login.revoke('lip_old');
    final delete = seen.single;
    expect(delete.method, 'DELETE');
    expect(delete.headers['Authorization'], 'Bearer lip_old');
    final broken = LichessLoginApi(
      MockClient((_) => throw const SocketException('down')),
      openBrowser: (_) async => true,
    );
    await broken.revoke('lip_old');
  });
}
