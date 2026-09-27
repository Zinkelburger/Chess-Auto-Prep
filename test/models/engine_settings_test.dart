import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/features/settings/controllers/engine_settings.dart';
import 'package:chess_auto_prep/features/settings/models/engine_configuration.dart';
import 'package:chess_auto_prep/constants/engine_defaults.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('defaults and invalid legacy values are immutable and valid', () {
    final defaults = EngineConfiguration();
    expect(defaults.cores, 1);
    expect(defaults.hashMb, kDefaultHashMb);
    expect(defaults.depth, kDefaultDepth);
    expect(defaults.multiPv, kDefaultMultiPv);
    expect(defaults.maxAnalysisMoves, kDefaultMaxAnalysisMoves);
    final legacy = EngineConfiguration({
      'engine_settings.cores': 999,
      'engine_settings.hash_mb': 4,
      'engine_settings.depth': 0,
      'engine_settings.multi_pv': 100,
      'engine_settings.explorer_database': 'broken',
      'engine_settings.explorer_speeds': '',
      'engine_settings.show_stockfish': 'invalid',
    }, 4);
    expect(legacy.cores, 4);
    expect(legacy.hashMb, kMinHashMb);
    expect(legacy.depth, kMinDepth);
    expect(legacy.multiPv, kMaxMultiPv);
    expect(legacy.explorerDatabase, 'lichess');
    expect(legacy.explorerSpeeds, kDefaultExplorerSpeeds);
    expect(legacy.showStockfish, isTrue);
    expect(
      () => legacy.values['engine_settings.depth'] = 40,
      throwsUnsupportedError,
    );
    expect(
      () => legacy.mutedAnalysisColumns.add('eval'),
      throwsUnsupportedError,
    );
  });
  test('legacy core migration and section edits survive restart', () async {
    SharedPreferences.setMockInitialValues({
      'engine_settings.workers': 1,
      'engine_settings.inline_threads': EngineSettings.systemCores,
      'engine_settings.depth': 25,
      'engine_settings.multi_pv': 5,
    });
    final settings = RuntimeSettings.preferences();
    addTearDown(settings.dispose);
    await settings.load();
    expect(settings.engine.cores, EngineSettings.systemCores);
    expect(settings.engine.depth, 25);
    await settings.engine.edit({'engine_settings.hash_mb': 256});
    final restarted = RuntimeSettings.preferences();
    addTearDown(restarted.dispose);
    await restarted.load();
    expect(restarted.engine.hashMb, 256);
    expect(restarted.engine.depth, 25);
    expect(restarted.engine.multiPv, 5);
  });
}
