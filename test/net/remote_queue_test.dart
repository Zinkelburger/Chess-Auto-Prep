import 'dart:async';

import 'package:chess_auto_prep/net/remote_queue.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('a request past the wait counts as not answered, and the next one '
      'goes out only once the slow one has settled', () {
    fakeAsync((async) {
      final slow = Completer<http.Response>();
      final sent = <String>[];
      final queue = RemoteQueue(
        MockClient((request) {
          sent.add(request.url.path);
          return request.url.path == '/slow'
              ? slow.future
              : Future.value(http.Response('ok', 200));
        }),
      );
      final run = queue.run();
      String? first = 'pending';
      String? second = 'pending';
      unawaited(
        run.get(Uri.https('example.com', '/slow')).then((b) => first = b),
      );
      unawaited(
        run.get(Uri.https('example.com', '/next')).then((b) => second = b),
      );

      async.elapse(RemoteQueue.wait + const Duration(seconds: 1));
      expect(first, isNull, reason: 'the caller is not kept waiting');
      expect(sent, ['/slow'], reason: 'the slow request is still out');
      expect(second, 'pending');

      async.elapse(const Duration(seconds: 30));
      expect(sent, ['/slow'], reason: 'the gate stays closed until it settles');

      slow.complete(http.Response('late', 200));
      async.flushMicrotasks();
      expect(sent, ['/slow', '/next']);
      expect(second, 'ok');
      expect(run.dropped, isFalse, reason: 'one slow answer is not an outage');
    });
  });

  test('a dropped run does not send what it had already queued, and '
      'another run is not kept waiting behind it', () {
    fakeAsync((async) {
      final client = _HangingClient();
      final queue = RemoteQueue(client);
      final runA = queue.run();
      final results = List<String?>.filled(10, 'pending');
      for (var i = 0; i < 10; i++) {
        unawaited(
          runA
              .get(Uri.https('example.com', '/a$i'))
              .then((b) => results[i] = b),
        );
      }

      for (var i = 0; i < RemoteRun.missesToDrop; i++) {
        async.elapse(RemoteQueue.wait + const Duration(milliseconds: 10));
      }
      expect(client.sent, ['/a0', '/a1', '/a2']);
      expect(runA.dropped, isTrue);
      expect(results, everyElement(isNull));

      String? fromB = 'pending';
      unawaited(
        queue.run().get(Uri.https('example.com', '/b')).then((b) => fromB = b),
      );
      async.flushMicrotasks();
      expect(client.sent.last, '/b');
      expect(fromB, 'ok');
    });
  });

  test('a closed run does not send what it had already queued', () {
    fakeAsync((async) {
      final client = _HangingClient();
      final run = RemoteQueue(client).run();
      final results = List<String?>.filled(5, 'pending');
      for (var i = 0; i < 5; i++) {
        unawaited(
          run.get(Uri.https('example.com', '/a$i')).then((b) => results[i] = b),
        );
      }
      async.flushMicrotasks();
      expect(client.sent, ['/a0']);

      run.close();
      async.elapse(RemoteQueue.wait + const Duration(milliseconds: 10));
      expect(client.sent, ['/a0']);
      expect(results, everyElement(isNull));
      expect(run.dropped, isFalse);
    });
  });

  test('a run asks at most its limit, a thousand unless told', () async {
    var sent = 0;
    final run = RemoteQueue(
      MockClient((_) async {
        sent++;
        return http.Response('ok', 200);
      }),
    ).run();
    for (var i = 0; i < 1000; i++) {
      expect(await run.get(Uri.https('example.com', '/$i')), 'ok');
    }
    expect(run.spent, isTrue);
    expect(await run.get(Uri.https('example.com', '/more')), isNull);
    expect(sent, 1000);
  });

  test('a closed run asks nothing more', () async {
    var sent = 0;
    final run = RemoteQueue(
      MockClient((_) async {
        sent++;
        return http.Response('ok', 200);
      }),
    ).run()..close();
    expect(await run.get(Uri.https('example.com', '/a')), isNull);
    expect(sent, 0);
  });

  test('an answer forgives the misses before it; three in a row after it '
      'stop the run', () async {
    final run = RemoteQueue(
      MockClient((request) async {
        if (request.url.path == '/ok') return http.Response('ok', 200);
        throw http.ClientException('offline');
      }),
    ).run();
    Future<void> ask(String path) => run.get(Uri.https('example.com', path));
    await ask('/miss');
    await ask('/miss');
    await ask('/ok');
    await ask('/miss');
    await ask('/miss');
    expect(run.dropped, isFalse);
    await ask('/miss');
    expect(run.dropped, isTrue);
  });

  test('a 500 stops the run; a 499 does not', () async {
    Future<bool> droppedBy(int status) async {
      final run = RemoteQueue(
        MockClient((_) async => http.Response('', status)),
      ).run();
      await run.get(Uri.https('example.com', '/a'));
      return run.dropped;
    }

    expect(await droppedBy(500), isTrue);
    expect(await droppedBy(499), isFalse);
  });

  test('a run closed while its request is out is not called dropped by the '
      'answer', () async {
    final answer = Completer<http.Response>();
    final run = RemoteQueue(MockClient((_) => answer.future)).run();
    final asking = run.get(Uri.https('example.com', '/a'));
    await pumpEventQueue();
    run.close();
    answer.complete(http.Response('', 429));
    await asking;
    expect(run.dropped, isFalse);
  });
}

/// Answers `/b` at once; every other request hangs until it is aborted.
final class _HangingClient extends http.BaseClient {
  final sent = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sent.add(request.url.path);
    if (request.url.path == '/b') {
      return Future.value(
        http.StreamedResponse(Stream.value('ok'.codeUnits), 200),
      );
    }
    final aborted = Completer<http.StreamedResponse>();
    unawaited(
      (request as http.Abortable).abortTrigger?.whenComplete(
        () => aborted.completeError(http.RequestAbortedException(request.url)),
      ),
    );
    return aborted.future;
  }
}
