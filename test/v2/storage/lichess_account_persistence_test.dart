import 'dart:async';

import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:chess_auto_prep/v2/storage/lichess_token.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed credentials wait for every accepted write and redact errors',
    () async {
      SharedPreferences.setMockInitialValues({});
      final backend = _Backend();
      SharedPreferencesStorePlatform.instance = backend;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final lines = <String>[];
      void sink(LogEntry entry) => lines.add(entry.line);
      log.install(sink);
      addTearDown(() => log.remove(sink));
      var settled = false;
      final saving =
          writeLichessAccount(
            const LichessAccount(
              token: 'private-test-token',
              username: 'Alice',
            ),
          ).then((result) {
            settled = true;
            return result;
          });
      await pumpEventQueue();
      expect(
        settled,
        isFalse,
        reason: 'a later accepted platform write is pending',
      );
      backend.last.complete(true);
      expect(await saving, isFalse);
      expect(lines.join(), isNot(contains('private-test-token')));
      expect(lines.join(), contains('preferences write failed'));
    },
  );
}

class _Backend extends InMemorySharedPreferencesStore {
  _Backend() : super.empty();
  final last = Completer<bool>();
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.$lichessTokenKey') throw StateError('$value');
    if (key == 'flutter.$lichessUsernameKey') return last.future;
    return super.setValue(type, key, value);
  }
}
