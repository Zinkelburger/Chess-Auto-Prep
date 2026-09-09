import 'package:chess_auto_prep/models/bulk_analysis_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'existing tactics depth carries over and new setting takes precedence',
    () async {
      SharedPreferences.setMockInitialValues({
        BulkAnalysisSettings.legacyPrefKey: 21,
      });
      final settings = BulkAnalysisSettings.forTest();
      addTearDown(settings.dispose);
      await settings.ensureLoaded();
      expect(settings.depth, 21);
      await settings.setDepth(18);
      final reloaded = BulkAnalysisSettings.forTest();
      addTearDown(reloaded.dispose);
      await reloaded.ensureLoaded();
      expect(reloaded.depth, 18);
      expect(await BulkAnalysisSettings.loadSavedDepth(), 18);
    },
  );

  test(
    'bulk depth accepts the engine range and clamps invalid values',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = BulkAnalysisSettings.forTest();
      addTearDown(settings.dispose);
      await settings.setDepth(30);
      expect(settings.depth, 30);
      await settings.setDepth(0);
      expect(settings.depth, 1);
      await settings.setDepth(1000);
      expect(settings.depth, 99);
    },
  );
}
