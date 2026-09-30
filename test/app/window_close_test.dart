import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:chess_auto_prep/app/window_close.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';

/// The window plugin's side of the channel: what the app asked of it, and a
/// close click sent the way the plugin sends one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> asked;

  setUp(() {
    asked = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      asked.add(call);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> clickClose() async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onEvent', {'eventName': 'close'}),
      ),
      (_) {},
    );
    await pumpEventQueue();
  }

  bool held(MethodCall call, bool value) =>
      call.method == 'setPreventClose' &&
      (call.arguments as Map)['isPreventClose'] == value;

  test('holds the window open so a close click reaches the exit', () async {
    final close = WindowClose(() async => AppExitResponse.cancel);
    await close.attach();
    expect(asked.where((c) => held(c, true)), hasLength(1));
    close.detach();
  });

  test('a close the exit refuses leaves the window up', () async {
    var asks = 0;
    final close = WindowClose(() async {
      asks++;
      return AppExitResponse.cancel;
    });
    await close.attach();
    await clickClose();
    expect(asks, 1);
    expect(asked.map((c) => c.method), isNot(contains('destroy')));
    close.detach();
  });

  test('a close the exit allows lets the window go', () async {
    final close = WindowClose(() async => AppExitResponse.exit);
    await close.attach();
    asked.clear();
    await clickClose();
    expect(held(asked.first, false), isTrue);
    expect(asked.last.method, 'destroy');
    close.detach();
  });

  test('a window that cannot be held still opens', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable');
    });
    final close = WindowClose(() async => AppExitResponse.exit);
    await close.attach();
    close.detach();
  });

  test('taken down, the close button closes the window again', () async {
    final close = WindowClose(() async => AppExitResponse.cancel);
    await close.attach();
    asked.clear();
    close.detach();
    await pumpEventQueue();
    expect(asked.where((c) => held(c, false)), hasLength(1));
    expect(windowManager.listeners, isNot(contains(close)));
  });

  test('taken down while still attaching, it leaves no listener and the '
      'window closable', () async {
    final initialized = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      asked.add(call);
      if (call.method == 'ensureInitialized') await initialized.future;
      return null;
    });
    var asks = 0;
    final close = WindowClose(() async {
      asks++;
      return AppExitResponse.exit;
    });
    final attaching = close.attach();
    await pumpEventQueue();
    close.detach();
    initialized.complete();
    await attaching;
    await pumpEventQueue();
    expect(windowManager.listeners, isNot(contains(close)));
    final holds = [
      for (final call in asked)
        if (call.method == 'setPreventClose')
          (call.arguments as Map)['isPreventClose'],
    ];
    expect(holds.lastOrNull ?? false, isFalse);
    await clickClose();
    expect(asks, 0, reason: 'a taken-down exit is not asked');
  });
}
