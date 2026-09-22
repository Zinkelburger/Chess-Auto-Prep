import 'package:chess_auto_prep/infrastructure/settings/fresh_desktop_preferences_store.dart';
import 'package:chess_auto_prep/infrastructure/settings/shared_preferences_app_settings_repository.dart';
import 'package:chess_auto_prep/features/settings/models/repertoire_books.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// Models the locked desktop plugin: per-instance cache mutates before its
/// whole-map disk write reports success/failure.
class _CachedBackend extends InMemorySharedPreferencesStore {
  _CachedBackend(this.disk, this.canWrite) : super.withData(disk);
  final Map<String, Object> disk;
  final bool Function() canWrite;

  Future<bool> _flush() async {
    if (!canWrite()) return false;
    final data = await super.getAllWithParameters(
      GetAllParameters(filter: PreferencesFilter(prefix: '')),
    );
    disk
      ..clear()
      ..addAll(data);
    return true;
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    await super.setValue(type, key, value);
    return _flush();
  }

  @override
  Future<bool> remove(String key) async {
    await super.remove(key);
    return _flush();
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    await super.clearWithParameters(parameters);
    return _flush();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, Object> disk;
  late FreshDesktopPreferencesStore platform;
  var writable = true;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    disk = {};
    writable = true;
    platform = FreshDesktopPreferencesStore(
      () => _CachedBackend(disk, () => writable),
    );
    SharedPreferencesStorePlatform.instance = platform;
  });
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  test(
    'false platform acknowledgement cannot publish or later resurrect a draft',
    () async {
      disk['flutter.my_repertoire_white_paths'] = ['/old'];
      final books = SharedPreferencesAppSettingsRepository().repertoireBooks;
      await books.ensureLoaded();
      writable = false;
      await expectLater(
        books.addPath(BookSide.white, '/new'),
        throwsStateError,
      );
      expect(books.state.committed!.white, ['/old']);
      writable = true;
      // An unrelated legacy setting must not flush the failed backend's cache.
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('display.mode', 'letters');
      expect(disk['flutter.my_repertoire_white_paths'], ['/old']);
      await books.retry();
      expect(disk['flutter.my_repertoire_white_paths'], ['/old', '/new']);
      expect(disk['flutter.display.mode'], 'letters');
    },
  );

  test('concurrent whole-map backend writes retain unrelated fields', () async {
    await Future.wait([
      platform.setValue('String', 'flutter.first', 'one'),
      platform.setValue('String', 'flutter.second', 'two'),
      platform.setValue('StringList', 'flutter.list', ['three']),
    ]);
    expect(disk, {
      'flutter.first': 'one',
      'flutter.second': 'two',
      'flutter.list': ['three'],
    });
    disk['flutter.external'] = 'four';
    expect((await platform.getAll())['flutter.external'], 'four');
  });

  test(
    'prefix, allow-list, remove and clear preserve their platform meaning',
    () async {
      disk.addAll({'flutter.a': 1, 'flutter.b': 2, 'custom.c': 3});
      expect(await platform.getAllWithPrefix('custom.'), {'custom.c': 3});
      await platform.clearWithParameters(
        ClearParameters(
          filter: PreferencesFilter(
            prefix: 'flutter.',
            allowList: {'flutter.a'},
          ),
        ),
      );
      expect(disk, {'flutter.b': 2, 'custom.c': 3});
      await platform.remove('custom.c');
      expect(disk, {'flutter.b': 2});
      await platform.clear();
      expect(disk, isEmpty);
    },
  );
}
