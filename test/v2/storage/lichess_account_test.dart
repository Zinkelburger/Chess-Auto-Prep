import 'package:chess_auto_prep/v2/storage/lichess_token.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('malformed credentials are signed out and removed', () async {
    SharedPreferences.setMockInitialValues({
      lichessTokenKey: 42,
      lichessUsernameKey: 'Someone',
    });
    expect(await readLichessAccount(), isNull);
    expect(await readLichessToken(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.get(lichessTokenKey), isNull);
    expect(prefs.get(lichessUsernameKey), isNull);
    expect(
      await writeLichessAccount(
        const LichessAccount(token: 't', username: 'A'),
      ),
      isTrue,
      reason: 'signing in again works',
    );
    expect(await readLichessToken(), 't');
  });

  test('nothing saved is no account and no token', () async {
    expect(await readLichessAccount(), isNull);
    expect(await readLichessToken(), isNull);
  });

  test('an OAuth account round-trips under the old app\'s keys', () async {
    final until = DateTime(2027, 9, 22, 12);
    expect(
      await writeLichessAccount(
        LichessAccount(token: 'lip_t', username: 'Someone', until: until),
      ),
      isTrue,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lichess_access_token'), 'lip_t');
    expect(prefs.getString('lichess_auth_username'), 'Someone');
    expect(prefs.getInt('lichess_token_expiry'), until.millisecondsSinceEpoch);
    expect(prefs.getBool('lichess_is_pat'), isFalse);
    final read = await readLichessAccount(now: DateTime(2026, 9, 22));
    expect(read?.token, 'lip_t');
    expect(read?.username, 'Someone');
    expect(read?.until, until);
    expect(read?.personal, isFalse);
    expect(await readLichessToken(), 'lip_t');
  });

  test('a personal token has no expiry and is marked as personal', () async {
    await writeLichessAccount(
      const LichessAccount(token: 'lip_p', username: 'Me', personal: true),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('lichess_token_expiry'), isFalse);
    expect(prefs.getBool('lichess_is_pat'), isTrue);
    final read = await readLichessAccount(now: DateTime(2099));
    expect(read?.personal, isTrue, reason: 'never expires');
  });

  test(
    'an expired OAuth token is reported as no account and cleared',
    () async {
      await writeLichessAccount(
        LichessAccount(
          token: 'lip_old',
          username: 'Old',
          until: DateTime(2025),
        ),
      );
      expect(await readLichessAccount(now: DateTime(2026)), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('lichess_access_token'), isFalse);
    },
  );

  test(
    'the old app\'s account, with a refresh key, is read and cleaned',
    () async {
      SharedPreferences.setMockInitialValues({
        'lichess_access_token': 'lip_shared',
        'lichess_refresh_token': 'stale',
        'lichess_auth_username': 'Shared',
        'lichess_is_pat': true,
      });
      final read = await readLichessAccount();
      expect(read?.username, 'Shared');
      await writeLichessAccount(read);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('lichess_refresh_token'), isFalse);
    },
  );

  test('forgetting removes every key', () async {
    await writeLichessAccount(
      LichessAccount(token: 'lip_t', username: 'S', until: DateTime(2027)),
    );
    expect(await writeLichessAccount(null), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });
}
