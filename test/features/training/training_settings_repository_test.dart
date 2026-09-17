import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/infrastructure/training/preferences_training_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'SET-01 queued saves capture each edit and survive adapter recreation',
    () async {
      SharedPreferences.setMockInitialValues({
        'trainer_uncapped_default_v1': true,
      });
      final repository = PreferencesTrainingSettings();
      final settings = TrainingSettings(moveSpeedMs: 250, trainingDepth: 8);
      final first = repository.save(settings);
      settings.moveSpeedMs = 900;
      final second = PreferencesTrainingSettings().save(settings);
      settings.moveSpeedMs = 1500;
      await first;
      await second;
      final restored = await PreferencesTrainingSettings().load();
      expect(restored.moveSpeedMs, 900);
      expect(restored.trainingDepth, 8);
    },
  );

  test(
    'SET-01 old default migration preserves explicit post-migration choices',
    () async {
      SharedPreferences.setMockInitialValues({
        'trainer_new_lines_per_session': 10,
        'trainer_reviews_per_session': 40,
      });
      final repository = PreferencesTrainingSettings();
      final migrated = await repository.load();
      expect(migrated.newLinesPerSession, 0);
      expect(migrated.reviewsPerSession, 0);
      migrated.newLinesPerSession = 10;
      await repository.save(migrated);
      expect(
        (await PreferencesTrainingSettings().load()).newLinesPerSession,
        10,
      );
    },
  );
}
