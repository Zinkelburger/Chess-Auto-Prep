import 'dart:io';

import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _CachePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _CachePaths(this.support);
  final String support;
  @override
  Future<String?> getApplicationSupportPath() async => support;
}

/// Registers a disposable SQLite cache for a test suite. Install before any
/// cache access: its current singleton keeps the first opened database.
/// Isolation is explicit even when flutter test is invoked outside ci.sh.
void useIsolatedEvalCache() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform previousPaths;
  late String databasePath;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('eval-cache-test-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _CachePaths(directory.path);
    databasePath = p.join(directory.path, 'eval_cache.db');
    await EvalCache.instance.init();
    // Fail before clear() if initialization fell back to memory or the cache
    // was already initialized elsewhere. Never clear an unverified database.
    expect(await File(databasePath).exists(), isTrue);
  });
  setUp(() async {
    await EvalCache.instance.clear();
    await MaiaCache.instance.clear();
  });
  tearDownAll(() async {
    await EvalCache.instance.flush();
    // The factory closes its cached connection before deleting the database.
    await databaseFactoryFfi.deleteDatabase(databasePath);
    PathProviderPlatform.instance = previousPaths;
    await directory.delete(recursive: true);
  });
}
