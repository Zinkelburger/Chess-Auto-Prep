import '../../settings/models/settings_state.dart';
import '../models/training_configuration.dart';

/// One application-owned writer shared by every training panel and sitting.
abstract interface class TrainingSettingsRepository {
  SettingsState<TrainingConfiguration> get state;
  Stream<SettingsState<TrainingConfiguration>> get changes;
  Future<void> ensureLoaded();
  Future<void> reload();
  Future<void> apply(TrainingSettingsPatch edit);
  Future<void> retry();
}

/// Persistence writes only the keys present in the captured field edit.
abstract interface class TrainingSettingsStorage {
  Future<TrainingConfiguration> read();
  Future<void> write(TrainingSettingsPatch edit);
}
