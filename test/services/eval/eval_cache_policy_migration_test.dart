import 'dart:io';
import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'old Maia policies are discarded while engine evaluations survive',
    () async {
      sqfliteFfiInit();
      final dir = Directory.systemTemp.createTempSync('maia-cache-upgrade-');
      PathProviderPlatform.instance = _Paths(dir.path);
      const fen = '8/8/8/8/8/4k3/P7/4K3 w - -';
      final db = await databaseFactoryFfi.openDatabase(
        '${dir.path}/eval_cache.db',
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE evals(fen TEXT PRIMARY KEY, eval_cp_white INTEGER NOT NULL, depth INTEGER NOT NULL, created_at INTEGER NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE maia_cache(fen TEXT NOT NULL, elo INTEGER NOT NULL, policy_json TEXT NOT NULL, win_prob REAL NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY(fen, elo))',
            );
            await db.insert('evals', {
              'fen': fen,
              'eval_cp_white': 37,
              'depth': 16,
              'created_at': 1,
            });
            await db.insert('maia_cache', {
              'fen': fen,
              'elo': 2200,
              'policy_json': '{"e1f1":1}',
              'win_prob': .5,
              'created_at': 1,
            });
          },
        ),
      );
      await db.close();
      expect(await EvalCache.instance.getEvalCpWhite(fen), 37);
      expect(await MaiaCache.instance.get(fen, 2200), isNull);
      await MaiaCache.instance.put(fen, 2200, {'e1d1': 1}, .6);
      expect((await MaiaCache.instance.get(fen, 2200))!.policy, {'e1d1': 1});
      await EvalCache.instance.flush();
    },
  );
}
