import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  final accounts = PreferencesAccounts();

  test(
    'a cached failed username write still retries platform persistence',
    () async {
      SharedPreferences.setMockInitialValues({});
      final backend = _Backend();
      SharedPreferencesStorePlatform.instance = backend;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      expect(await accounts.setUsername(GameSite.lichess, 'Alice'), isFalse);
      backend.reject = false;
      expect(await accounts.setUsername(GameSite.lichess, 'Alice'), isTrue);
      expect(backend.names, ['Alice', 'Alice']);
      expect((await backend.getAll())['flutter.lichess_username'], 'Alice');
    },
  );

  test('reads the usernames and dates the old app saved', () async {
    SharedPreferences.setMockInitialValues({
      'lichess_username': 'Me',
      'lichess_last_fetch_ms': DateTime(2026, 9, 1).millisecondsSinceEpoch,
      'chesscom_username': '  ',
    });
    final read = await accounts.read();
    expect(read.keys, [GameSite.lichess]);
    expect(read[GameSite.lichess]?.username, 'Me');
    expect(read[GameSite.lichess]?.downloaded, DateTime(2026, 9, 1));
  });

  test('writes under the same keys; another name forgets the date, the same '
      'name keeps it', () async {
    SharedPreferences.setMockInitialValues({
      'chesscom_username': 'old',
      'chesscom_last_fetch_ms': 5,
    });
    final prefs = await SharedPreferences.getInstance();

    expect(await accounts.setUsername(GameSite.chesscom, ' old '), isTrue);
    expect(prefs.getInt('chesscom_last_fetch_ms'), 5);

    expect(await accounts.setUsername(GameSite.chesscom, 'new'), isTrue);
    expect(prefs.getString('chesscom_username'), 'new');
    expect(prefs.getInt('chesscom_last_fetch_ms'), isNull);

    await accounts.setDownloaded(GameSite.chesscom, DateTime(2026, 9, 22));
    expect(
      prefs.getInt('chesscom_last_fetch_ms'),
      DateTime(2026, 9, 22).millisecondsSinceEpoch,
    );

    expect(await accounts.setUsername(GameSite.chesscom, ''), isTrue);
    expect(prefs.containsKey('chesscom_username'), isFalse);
  });
}

class _Backend extends InMemorySharedPreferencesStore {
  _Backend() : super.empty();
  bool reject = true;
  final names = <Object>[];
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.lichess_username') {
      names.add(value);
      if (reject) return false;
    }
    return super.setValue(type, key, value);
  }
}
