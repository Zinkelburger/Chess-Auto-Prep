/// Exercises the MCP bridge's HTTP surface for real: a bound socket, actual
/// requests, and the auth path.
///
/// Everything here was previously "reads correctly" rather than "runs" — and
/// the auth check in particular is the only thing standing between a local
/// process and the ability to drive the app.
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/tournament/mcp/prep_server.dart';
import 'package:chess_auto_prep/features/tournament/models/roster_entry.dart';
import 'package:chess_auto_prep/features/tournament/services/player_directory.dart';
import 'package:chess_auto_prep/features/tournament/services/tournament_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

late Directory tempDir;
late TournamentSession session;
late PrepServer server;
late String base;
late String token;

Future<HttpClientResponse> request(
  String method,
  String path, {
  Object? body,
  String? bearer = '__use_real__',
}) async {
  final client = HttpClient();
  final req = await client.openUrl(method, Uri.parse('$base$path'));
  final auth = bearer == '__use_real__' ? token : bearer;
  if (auth != null) req.headers.set('authorization', 'Bearer $auth');
  if (body != null) {
    req.headers.contentType = ContentType.json;
    req.write(json.encode(body));
  }
  return req.close();
}

Future<Map<String, dynamic>> jsonOf(HttpClientResponse r) async =>
    json.decode(await r.transform(utf8.decoder).join()) as Map<String, dynamic>;

void main() {
  setUp(() async {
    PlayerDirectory.overrideInstanceForTest(
      PlayerDirectory.fromJson(
        mapping: {
          'events_processed': 5,
          'players': {
            '12345678': {
              'u': 'someone',
              'n': 'Test Player',
              'c': 'exact',
              'm': 'opponent_graph',
            },
          },
        },
      ),
    );

    tempDir = await Directory.systemTemp.createTemp('prep_server_test');
    session = TournamentSession();
    server = PrepServer(session);
    await server.start(endpointDirectory: tempDir);
    base = 'http://127.0.0.1:${server.port}';
    token = server.token!;
  });

  tearDown(() async {
    await server.stop();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('lifecycle', () {
    test('binds a loopback port and reports it', () {
      expect(server.isRunning, isTrue);
      expect(server.port, greaterThan(0));
      expect(server.token, isNotNull);
      expect(server.token!.length, greaterThan(20));
    });

    test('writes a descriptor the shim can discover', () async {
      final file = File(p.join(tempDir.path, kMcpEndpointFileName));
      expect(await file.exists(), isTrue);

      final descriptor =
          json.decode(await file.readAsString()) as Map<String, dynamic>;
      expect(descriptor['url'], 'http://127.0.0.1:${server.port}');
      expect(descriptor['token'], token);
    });

    test('stop closes the port and deletes the descriptor', () async {
      final file = File(p.join(tempDir.path, kMcpEndpointFileName));
      await server.stop();

      expect(server.isRunning, isFalse);
      expect(await file.exists(), isFalse);
      await expectLater(
        HttpClient().getUrl(Uri.parse('$base/health')).then((r) => r.close()),
        throwsA(isA<SocketException>()),
      );
    });

    test('mints a different token on each start', () async {
      final first = server.token;
      await server.stop();
      await server.start(endpointDirectory: tempDir);
      expect(server.token, isNot(first));
    });
  });

  group('auth', () {
    test('rejects a request with no token', () async {
      final r = await request('GET', '/health', bearer: null);
      expect(r.statusCode, HttpStatus.unauthorized);
    });

    test('rejects a wrong token', () async {
      final r = await request('GET', '/health', bearer: 'not-the-token');
      expect(r.statusCode, HttpStatus.unauthorized);
    });

    test('rejects a token that is a prefix of the real one', () async {
      final r = await request(
        'GET',
        '/health',
        bearer: token.substring(0, token.length - 1),
      );
      expect(r.statusCode, HttpStatus.unauthorized);
    });

    test('accepts the real token', () async {
      final r = await request('GET', '/health');
      expect(r.statusCode, HttpStatus.ok);
    });
  });

  group('endpoints', () {
    test('GET /health reports app state', () async {
      final body = await jsonOf(await request('GET', '/health'));
      expect(body['ok'], isTrue);
      expect(body['tools'], greaterThan(0));
      expect(body['roster_entries'], 0);
      expect(body['preparing'], isFalse);
    });

    test('GET /tools returns MCP-shaped definitions', () async {
      final body = await jsonOf(await request('GET', '/tools'));
      final tools = (body['tools'] as List).cast<Map<String, dynamic>>();

      expect(tools, isNotEmpty);
      for (final t in tools) {
        expect(t['name'], isA<String>());
        expect(t['description'], isA<String>());
        expect(t['inputSchema'], isA<Map>());
        expect((t['inputSchema'] as Map)['type'], 'object');
      }
      expect(tools.map((t) => t['name']), contains('prep_run'));
    });

    test('serves non-ASCII tool text intact', () async {
      // Regression: HttpResponse.write() encodes with the content type's
      // charset and defaults to latin1, so the `→` and `—` in the tool
      // descriptions made every /tools call throw. That is the first request
      // an MCP client makes after initialize, so the bridge was dead on
      // arrival while still looking correct in review.
      final r = await request('GET', '/tools');
      expect(r.statusCode, HttpStatus.ok);

      final raw = await r.transform(utf8.decoder).join();
      final tools = ((json.decode(raw) as Map)['tools'] as List)
          .cast<Map<String, dynamic>>();

      expect(
        tools.map((t) => t['description'] as String).join(),
        contains('×'),
        reason: 'non-ASCII must survive the round trip, not be mangled',
      );
      expect(
        r.headers.contentType?.charset,
        'utf-8',
        reason: 'clients need to be told how to decode it',
      );
    });

    test('POST /call runs a tool and returns its result', () async {
      final body = await jsonOf(
        await request(
          'POST',
          '/call',
          body: {'name': 'repertoire_list', 'arguments': <String, dynamic>{}},
        ),
      );

      expect(body['ok'], isTrue);
      expect((body['result'] as Map)['repertoires'], isA<List>());
    });

    test('POST /call reports a tool error as data, not a crash', () async {
      final body = await jsonOf(
        await request(
          'POST',
          '/call',
          body: {'name': 'prep_run', 'arguments': <String, dynamic>{}},
        ),
      );

      expect(body['ok'], isFalse);
      expect(body['error'], contains('repertoire'));
    });

    test('POST /call rejects an unknown tool', () async {
      final body = await jsonOf(
        await request('POST', '/call', body: {'name': 'nope'}),
      );
      expect(body['ok'], isFalse);
      expect(body['error'], contains('Unknown tool'));
    });

    test('POST /call requires a name', () async {
      final r = await request('POST', '/call', body: <String, dynamic>{});
      expect(r.statusCode, HttpStatus.badRequest);
    });

    test('malformed JSON does not take the server down', () async {
      final client = HttpClient();
      final req = await client.postUrl(Uri.parse('$base/call'));
      req.headers.set('authorization', 'Bearer $token');
      req.write('{not json');
      final r = await req.close();
      await r.drain<void>();
      expect(r.statusCode, HttpStatus.internalServerError);

      // Still serving.
      expect((await request('GET', '/health')).statusCode, HttpStatus.ok);
    });

    test('unknown paths 404', () async {
      final r = await request('GET', '/nope');
      expect(r.statusCode, HttpStatus.notFound);
    });
  });

  test('the bridge reads the same session the UI shows', () async {
    session.setRoster(
      const Roster(
        eventName: 'Bridge Test',
        entries: [RosterEntry(id: 'a', name: 'A', rating: 1800, isMe: true)],
      ),
    );

    final body = await jsonOf(
      await request(
        'POST',
        '/call',
        body: {'name': 'roster_get', 'arguments': <String, dynamic>{}},
      ),
    );
    expect((body['result'] as Map)['event_name'], 'Bridge Test');

    final health = await jsonOf(await request('GET', '/health'));
    expect(health['roster_entries'], 1);
  });
}
