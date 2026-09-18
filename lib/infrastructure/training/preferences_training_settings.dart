import 'package:shared_preferences/shared_preferences.dart';
import '../../features/training/models/training_settings.dart';
import '../../features/training/models/training_configuration.dart';
import '../settings/preferences_section_storage.dart';

class PreferencesTrainingSettings
    extends PreferencesSectionStorage<TrainingConfiguration> {
  PreferencesTrainingSettings()
    : super(
        keys: TrainingConfiguration(TrainingSettings()).values.keys.toSet(),
        decode: TrainingConfiguration.fromValues,
      );

  @override
  Future<TrainingConfiguration> read() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    // Old versions silently imposed these caps. Migrate those defaults once;
    // explicit sizes chosen after this migration remain user preferences.
    if (!(prefs.getBool('trainer_uncapped_default_v1') ?? false)) {
      if (prefs.getInt('trainer_new_lines_per_session') == 10) {
        await _write(prefs.setInt('trainer_new_lines_per_session', 0));
      }
      if (prefs.getInt('trainer_reviews_per_session') == 40) {
        await _write(prefs.setInt('trainer_reviews_per_session', 0));
      }
      await _write(prefs.setBool('trainer_uncapped_default_v1', true));
    }
    return super.read();
  }

  Future<void> _write(Future<bool> result) async {
    if (!await result) throw StateError('Training preferences were not saved.');
  }
}
