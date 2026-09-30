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
      run.get(Uri.https('example.com', '/slow')).then((b) => first = b);
      run.get(Uri.https('example.com', '/next')).then((b) => second = b);

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
        runA.get(Uri.https('example.com', '/a$i')).then((b) => results[i] = b);
      }

      for (var i = 0; i < RemoteRun.missesToDrop; i++) {
        async.elapse(RemoteQueue.wait + const Duration(milliseconds: 10));
      }
      expect(client.sent, ['/a0', '/a1', '/a2']);
      expect(runA.dropped, isTrue);
      expect(results, everyElement(isNull));

      String? fromB = 'pending';
      queue.run().get(Uri.https('example.com', '/b')).then((b) => fromB = b);
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
        run.get(Uri.https('example.com', '/a$i')).then((b) => results[i] = b);
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
    (request as http.Abortable).abortTrigger?.whenComplete(
      () => aborted.completeError(http.RequestAbortedException(request.url)),
    );
    return aborted.future;
  }
}
