import '../models/training_settings.dart';

abstract interface class TrainingSettingsRepository {
  Future<TrainingSettings> load();
  Future<void> save(TrainingSettings settings);
}
