import 'dart:async';

import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:chess_auto_prep/v2/storage/lichess_token.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed expiry cleanup remains unavailable and retries its removal',
    () async {
      SharedPreferences.setMockInitialValues({
        lichessTokenKey: 'expired',
        lichessExpiryKey: DateTime(2020).millisecondsSinceEpoch,
      });
      await SharedPreferences.getInstance();
      final backend = _RemovalBackend();
      SharedPreferencesStorePlatform.instance = backend;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      await expectLater(readLichessAccount(), throwsA(isA<Exception>()));
      backend.fail = false;
      expect(await readLichessAccount(), isNull);
      expect(backend.removals, 10);
    },
  );

  test(
    'expiry removal cannot interleave with a newer accepted account',
    () async {
      SharedPreferences.setMockInitialValues({
        lichessTokenKey: 'expired',
        lichessUsernameKey: 'Old',
        lichessExpiryKey: DateTime(2020).millisecondsSinceEpoch,
      });
      await SharedPreferences.getInstance();
      final backend = _ExpiryBackend();
      SharedPreferencesStorePlatform.instance = backend;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final expired = readLichessAccount(now: DateTime(2026));
      await backend.removing.future;
      final replacement = writeLichessAccount(
        const LichessAccount(token: 'new', username: 'New', personal: true),
      );
      await pumpEventQueue();
      expect(
        backend.writes,
        0,
        reason: 'expiry owns the credential keys until removal settles',
      );
      backend.release.complete(true);
      expect(await expired, isNull);
      expect(await replacement, isTrue);
      final read = await readLichessAccount();
      expect(read?.token, 'new');
      expect(read?.username, 'New');
      expect(read?.personal, isTrue);
    },
  );

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
      await expectLater(
        readLichessAccount(),
        throwsA(isA<Exception>()),
        reason: 'the optimistic plugin cache is not an acknowledged account',
      );
      expect(await readLichessToken(), isNull);
      expect(lines.join(), isNot(contains('private-test-token')));
      expect(lines.join(), contains('preferences write failed'));
      backend.fails = false;
      expect(
        await writeLichessAccount(
          const LichessAccount(token: 'confirmed', username: 'Alice'),
        ),
        isTrue,
      );
      expect((await readLichessAccount())?.token, 'confirmed');
    },
  );
}

class _Backend extends InMemorySharedPreferencesStore {
  _Backend() : super.empty();
  final last = Completer<bool>();
  bool fails = true;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (fails && key == 'flutter.$lichessTokenKey') throw StateError('$value');
    if (key == 'flutter.$lichessUsernameKey') return last.future;
    return super.setValue(type, key, value);
  }
}

class _ExpiryBackend extends InMemorySharedPreferencesStore {
  _ExpiryBackend() : super.empty();
  final removing = Completer<void>();
  final release = Completer<bool>();
  int writes = 0;

  @override
  Future<bool> remove(String key) async {
    if (key == 'flutter.$lichessTokenKey' && !removing.isCompleted) {
      removing.complete();
      await release.future;
    }
    return super.remove(key);
  }

  @override
  Future<bool> setValue(String type, String key, Object value) {
    writes++;
    return super.setValue(type, key, value);
  }
}

class _RemovalBackend extends InMemorySharedPreferencesStore {
  _RemovalBackend() : super.empty();
  bool fail = true;
  int removals = 0;
  @override
  Future<bool> remove(String key) async {
    removals++;
    return fail ? false : super.remove(key);
  }
}
