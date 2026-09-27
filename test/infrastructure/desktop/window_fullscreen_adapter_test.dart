import 'dart:async';

import 'package:chess_auto_prep/infrastructure/desktop/window_fullscreen_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  late WindowFullscreenAdapter adapter;
  late List<MethodCall> calls;
  setUp(() {
    calls = [];
    adapter = WindowFullscreenAdapter();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'isFullScreen' ? true : null;
    });
  });
  tearDown(() {
    adapter.detach();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> event(String name) async {
    final done = Completer<void>();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        MethodCall('onEvent', {'eventName': name}),
      ),
      (_) => done.complete(),
    );
    await done.future;
  }

  test(
    'reads native state, dispatches fullscreen and detaches only its own listener',
    () async {
      final other = WindowFullscreenAdapter();
      addTearDown(other.detach);
      final otherEvents = <bool>[];
      await other.attach(otherEvents.add);
      final events = <bool>[];
      expect(await adapter.attach(events.add), isTrue);
      expect(
        windowManager.listeners.where((value) => identical(value, adapter)),
        hasLength(1),
      );
      await event('leave-full-screen');
      await event('enter-full-screen');
      expect(events, [false, true]);
      await adapter.setFullScreen(false);
      expect(calls.last.method, 'setFullScreen');
      expect(calls.last.arguments, {'isFullScreen': false});
      adapter.detach();
      await event('leave-full-screen');
      expect(events, [false, true]);
      expect(otherEvents, [false, true, false]);
      expect(windowManager.listeners, isNot(contains(adapter)));
    },
  );

  test(
    'reattaching replaces the callback without duplicate listeners',
    () async {
      final oldEvents = <bool>[];
      final events = <bool>[];
      await adapter.attach(oldEvents.add);
      await adapter.attach(events.add);
      await event('enter-full-screen');
      expect(events, [true]);
      expect(oldEvents, isEmpty);
      expect(
        windowManager.listeners.where((value) => identical(value, adapter)),
        hasLength(1),
      );
    },
  );
}
