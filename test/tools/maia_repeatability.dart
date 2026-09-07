/// Opt-in native Maia regression. Run via scripts/ci.sh test with ORT available.
library;

import 'dart:io';
import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:chess_auto_prep/services/maia/maia_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'first, repeated and fresh-session policies agree without cached results',
    () async {
      final dir = Directory.systemTemp.createTempSync('maia-repeatability-');
      PathProviderPlatform.instance = _Paths(dir.path);
      SharedPreferences.setMockInitialValues({});
      const fen = '8/8/8/8/P7/3k4/8/4K3 b - - 0 2';
      MaiaResult? first;
      for (var session = 0; session < 2; session++) {
        final maia = MaiaService.fresh();
        try {
          await maia.initialize();
          for (var i = 0; i < 3; i++) {
            await MaiaCache.instance.clear();
            final result = await maia.evaluate(fen, 2200);
            expect(result.policy, isNotEmpty);
            if (first == null) {
              first = result;
            } else {
              expect(result.policy, first.policy);
              expect(result.winProbability, first.winProbability);
            }
          }
        } finally {
          maia.dispose();
        }
      }
      await EvalCache.instance.flush();
      // The process owns the disposable profile; no real app cache was opened.
    },
  );
}
