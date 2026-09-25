import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:chess_auto_prep/v2/storage/lichess_token.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => SharedPreferences.setMockInitialValues({}));

  test('an expired token that cannot be removed still reads as signed out '
      'and does not block a new login', () async {
    SharedPreferences.setMockInitialValues({
      lichessTokenKey: 'expired',
      lichessExpiryKey: DateTime(2020).millisecondsSinceEpoch,
    });
    await SharedPreferences.getInstance();
    final backend = _Backend(failRemovals: true);
    SharedPreferencesStorePlatform.instance = backend;
    expect(await readLichessAccount(), isNull);
    expect(await readLichessToken(), isNull);
    backend.failRemovals = false;
    expect(
      await writeLichessAccount(
        const LichessAccount(token: 'new', username: 'New', personal: true),
      ),
      isTrue,
    );
    expect(await readLichessToken(), 'new');
  });

  test('a failed write says so, never logs the token, and the next write '
      'works', () async {
    SharedPreferences.setMockInitialValues({});
    final backend = _Backend(failToken: true);
    SharedPreferencesStorePlatform.instance = backend;
    final lines = <String>[];
    void sink(LogEntry entry) => lines.add(entry.line);
    log.install(sink);
    addTearDown(() => log.remove(sink));
    expect(
      await writeLichessAccount(
        const LichessAccount(token: 'private-test-token', username: 'Alice'),
      ),
      isFalse,
    );
    expect(lines.join(), isNot(contains('private-test-token')));
    backend.failToken = false;
    expect(
      await writeLichessAccount(
        const LichessAccount(token: 'confirmed', username: 'Alice'),
      ),
      isTrue,
    );
    expect((await readLichessAccount())?.token, 'confirmed');
  });
}

class _Backend extends InMemorySharedPreferencesStore {
  _Backend({this.failRemovals = false, this.failToken = false})
    : super.empty();
  bool failRemovals;
  bool failToken;

  @override
  Future<bool> remove(String key) async =>
      failRemovals ? false : super.remove(key);

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (failToken && key == 'flutter.$lichessTokenKey') {
      throw StateError('$value');
    }
    return super.setValue(type, key, value);
  }
}
