import 'dart:async';

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

  test('failed date acknowledgement never becomes cached freshness', () async {
    SharedPreferences.setMockInitialValues({'lichess_username': 'Me'});
    await SharedPreferences.getInstance();
    final backend = _Backend()..rejectDates = true;
    SharedPreferencesStorePlatform.instance = backend;
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    final source = PreferencesAccounts();
    final when = DateTime(2026, 9, 24);
    expect(
      await source.setDownloaded(
        GameSite.lichess,
        when,
        expectedUsername: 'Me',
      ),
      isFalse,
    );
    expect((await source.read())[GameSite.lichess]!.downloaded, isNull);
    backend.rejectDates = false;
    expect(
      await source.setDownloaded(
        GameSite.lichess,
        when,
        expectedUsername: 'Me',
      ),
      isTrue,
    );
    expect((await source.read())[GameSite.lichess]!.downloaded, when);
  });

  test(
    'a delayed old account date cannot stamp the replacement username',
    () async {
      SharedPreferences.setMockInitialValues({'lichess_username': 'Old'});
      final source = PreferencesAccounts();
      final rename = source.setUsername(GameSite.lichess, 'New');
      final stamp = source.setDownloaded(
        GameSite.lichess,
        DateTime(2026),
        expectedUsername: 'Old',
      );
      expect(await rename, isTrue);
      expect(await stamp, isFalse);
      expect((await source.read())[GameSite.lichess]!.downloaded, isNull);
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
  test(
    'typed snapshot reports platform read failure instead of empty names',
    () async {
      final unavailable = PreferencesAccounts(
        preferences: () async => throw StateError('preferences unavailable'),
      );
      expect(await unavailable.snapshot(), isA<AccountsUnavailable>());
      expect(await unavailable.read(), isEmpty);
    },
  );

  test('username admission changes revision before its first await', () async {
    SharedPreferences.setMockInitialValues({'lichess_username': 'Old'});
    final prefs = await SharedPreferences.getInstance();
    final gate = Completer<SharedPreferences>();
    var held = false;
    final source = PreferencesAccounts(
      preferences: () => held ? gate.future : Future.value(prefs),
    );
    final old = await source.snapshot() as AccountsSnapshot;
    held = true;
    final write = source.setUsername(GameSite.lichess, 'New');
    expect(source.revision, isNot(old.revision));
    expect(await source.snapshot(), isA<AccountsUnavailable>());
    gate.complete(prefs);
    expect(await write, isTrue);
    expect(
      (await source.snapshot() as AccountsSnapshot)
          .accounts[GameSite.lichess]!
          .username,
      'New',
    );
  });

  test(
    'failed cached username publication is unavailable until confirmed retry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final backend = _Backend();
      SharedPreferencesStorePlatform.instance = backend;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final source = PreferencesAccounts();
      expect(await source.setUsername(GameSite.lichess, 'Alice'), isFalse);
      expect(await source.snapshot(), isA<AccountsUnavailable>());
      backend.reject = false;
      expect(await source.setUsername(GameSite.lichess, 'Alice'), isTrue);
      expect(
        (await source.snapshot() as AccountsSnapshot)
            .accounts[GameSite.lichess]!
            .username,
        'Alice',
      );
    },
  );

  test(
    'captured names are immutable and later observations advance revision',
    () async {
      SharedPreferences.setMockInitialValues({'lichess_username': 'Old'});
      final source = PreferencesAccounts();
      final old = await source.snapshot() as AccountsSnapshot;
      expect(() => old.accounts.clear(), throwsUnsupportedError);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lichess_username', 'New');
      final current = await source.snapshot() as AccountsSnapshot;
      expect(current.revision, isNot(old.revision));
      expect(old.accounts[GameSite.lichess]!.username, 'Old');
      expect(current.accounts[GameSite.lichess]!.username, 'New');
    },
  );

  test(
    'a read begun before username admission cannot publish afterward',
    () async {
      SharedPreferences.setMockInitialValues({'lichess_username': 'Old'});
      final prefs = await SharedPreferences.getInstance();
      final oldRead = Completer<SharedPreferences>();
      var calls = 0;
      final source = PreferencesAccounts(
        preferences: () => ++calls == 1 ? oldRead.future : Future.value(prefs),
      );
      final pending = source.snapshot();
      expect(await source.setUsername(GameSite.lichess, 'New'), isTrue);
      final current = await source.snapshot() as AccountsSnapshot;
      oldRead.complete(prefs);
      expect(await pending, isA<AccountsUnavailable>());
      expect(source.revision, current.revision);
      expect(
        (await source.snapshot() as AccountsSnapshot)
            .accounts[GameSite.lichess]!
            .username,
        'New',
      );
    },
  );

  test('another site succeeding does not confirm a failed username', () async {
    SharedPreferences.setMockInitialValues({});
    final backend = _Backend();
    SharedPreferencesStorePlatform.instance = backend;
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    final source = PreferencesAccounts();
    expect(await source.setUsername(GameSite.lichess, 'Alice'), isFalse);
    expect(await source.setUsername(GameSite.chesscom, 'Bob'), isTrue);
    expect(await source.snapshot(), isA<AccountsUnavailable>());
    backend.reject = false;
    expect(await source.setUsername(GameSite.lichess, 'Alice'), isTrue);
    final current = await source.snapshot() as AccountsSnapshot;
    expect(current.accounts.keys, containsAll(GameSite.values));
  });

  test(
    'observed read failure invalidates the last successful revision',
    () async {
      SharedPreferences.setMockInitialValues({'lichess_username': 'Old'});
      var fail = false;
      final source = PreferencesAccounts(
        preferences: () async {
          if (fail) throw StateError('unavailable');
          return SharedPreferences.getInstance();
        },
      );
      final good = await source.snapshot() as AccountsSnapshot;
      fail = true;
      expect(await source.snapshot(), isA<AccountsUnavailable>());
      expect(source.revision, isNot(good.revision));
      final failedRevision = source.revision;
      expect(await source.snapshot(), isA<AccountsUnavailable>());
      expect(source.revision, failedRevision);
      fail = false;
      final restored = await source.snapshot() as AccountsSnapshot;
      expect(restored.revision, greaterThan(failedRevision));
      expect(restored.accounts[GameSite.lichess]!.username, 'Old');
    },
  );
}

class _Backend extends InMemorySharedPreferencesStore {
  _Backend() : super.empty();
  bool reject = true;
  bool rejectDates = false;
  final names = <Object>[];
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.lichess_last_fetch_ms' && rejectDates) return false;
    if (key == 'flutter.lichess_username') {
      names.add(value);
      if (reject) return false;
    }
    return super.setValue(type, key, value);
  }
}
