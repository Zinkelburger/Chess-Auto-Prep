import 'package:chess_auto_prep/services/file_open_requests.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(FileOpenRequests.channelName);
  const codec = StandardMethodCodec();
  late List<List<String>> opened;
  late FileOpenRequests requests;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Pretend the runner queued [pending] before Dart was ready.
  void runnerHas(List<String> pending) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'ready');
      return pending;
    });
  }

  /// Pretend the runner forwarded [paths] from a second instance.
  Future<void> runnerOpens(List<Object?> paths) async {
    await messenger.handlePlatformMessage(
      FileOpenRequests.channelName,
      codec.encodeMethodCall(MethodCall('open', paths)),
      (_) {},
    );
  }

  setUp(() {
    opened = [];
    requests = FileOpenRequests(onOpen: opened.add);
  });

  tearDown(() {
    requests.stop();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('drains files the runner queued before Dart was ready', () async {
    runnerHas(['/games/a.pgn']);
    await requests.start();
    expect(opened, [
      ['/games/a.pgn'],
    ]);
  });

  test('delivers files forwarded while running', () async {
    runnerHas([]);
    await requests.start();
    await runnerOpens(['/games/b.pgn', '/games/c.pgn']);
    expect(opened, [
      ['/games/b.pgn', '/games/c.pgn'],
    ]);
  });

  test('an empty queue is silence, not an empty open', () async {
    runnerHas([]);
    await requests.start();
    await runnerOpens([]);
    await runnerOpens(['', '  ']);
    expect(opened, isEmpty);
  });

  test('keeps only string paths from a malformed payload', () async {
    runnerHas([]);
    await requests.start();
    await runnerOpens([42, '/games/d.pgn', null]);
    expect(opened, [
      ['/games/d.pgn'],
    ]);
  });

  test('a platform with no runner support stays quiet', () async {
    // No mock handler: the ready call is a MissingPluginException.
    await requests.start();
    expect(opened, isEmpty);
  });

  test('nothing arrives after stop', () async {
    runnerHas([]);
    await requests.start();
    requests.stop();
    await runnerOpens(['/games/e.pgn']);
    expect(opened, isEmpty);
  });
}
