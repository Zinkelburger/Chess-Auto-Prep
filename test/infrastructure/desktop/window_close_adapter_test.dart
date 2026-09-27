import 'package:chess_auto_prep/infrastructure/desktop/window_close_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  late List<MethodCall> calls;
  var failClose = false;
  setUp(() {
    calls = [];
    failClose = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'close' && failClose) {
            throw PlatformException(code: 'close-failed');
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'native adapter owns prevention and forwards requests without closing',
    () async {
      final adapter = WindowCloseAdapter();
      var requests = 0;
      await adapter.attach(() => requests++);
      adapter.onWindowClose();
      expect(requests, 1);
      expect(calls.map((c) => c.method), ['setPreventClose']);
      expect(calls.single.arguments, {'isPreventClose': true});
      await adapter.close();
      expect(calls.map((c) => c.method), [
        'setPreventClose',
        'setPreventClose',
        'close',
      ]);
      expect(calls[1].arguments, {'isPreventClose': false});
      await adapter.detach();
      adapter.onWindowClose();
      expect(requests, 1);
    },
  );
  test(
    'failed native closure restores prevention before surfacing failure',
    () async {
      final adapter = WindowCloseAdapter();
      await adapter.attach(() {});
      failClose = true;
      await expectLater(adapter.close(), throwsA(isA<PlatformException>()));
      expect(calls.last.method, 'setPreventClose');
      expect(calls.last.arguments, {'isPreventClose': true});
      await adapter.detach();
    },
  );
}
