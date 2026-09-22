import '../../settings/controllers/section_settings_owner.dart';
import '../../settings/repositories/settings_section_storage.dart';
import '../models/training_configuration.dart';
import '../models/training_settings.dart';

/// Shared training preferences; active sittings retain their captured settings.
class TrainingSettingsController
    extends SectionSettingsOwner<TrainingConfiguration> {
  TrainingSettingsController(
    SettingsSectionStorage<TrainingConfiguration> storage,
  ) : super(storage, TrainingConfiguration(TrainingSettings()));
}
